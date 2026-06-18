import AVFoundation
import Combine
import CoreLocation
@preconcurrency import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import FirebaseStorage
import UIKit

// MARK: - Upload pipeline (extracted from SocialService)
//
// The post-upload pipeline — media processing, Storage upload with byte
// progress, place resolution, video thumbnails — lifted out of
// SocialService.swift to shrink that file. This is the SAME @Observable object
// (an `extension`), so the public API (`enqueuePost`/`retryUpload`) and every
// view call site are unchanged; `runUpload`/`friendlyUploadError` stay in the
// main file since they own `savedUpload`/`isUploadingPost`.
extension SocialService {
    /// Uploads `Data` to `ref` reporting byte-accurate fractional progress.
    /// `nonisolated` so the Storage callbacks (main-queue) don't entangle the
    /// actor; progress is hopped back to the main actor by the caller's closure.
    nonisolated private func putDataTracked(
        _ data: Data, to ref: StorageReference,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = ref.putData(data, metadata: nil)
            task.observe(.progress) { snapshot in
                if let p = snapshot.progress, p.totalUnitCount > 0 {
                    onProgress(Double(p.completedUnitCount) / Double(p.totalUnitCount))
                }
            }
            task.observe(.success) { _ in cont.resume() }
            task.observe(.failure) { snapshot in
                cont.resume(throwing: snapshot.error ?? SocialError.uploadFailed)
            }
        }
    }

    /// File variant of `putDataTracked` for video uploads.
    nonisolated private func putFileTracked(
        from url: URL, to ref: StorageReference,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = ref.putFile(from: url, metadata: nil)
            task.observe(.progress) { snapshot in
                if let p = snapshot.progress, p.totalUnitCount > 0 {
                    onProgress(Double(p.completedUnitCount) / Double(p.totalUnitCount))
                }
            }
            task.observe(.success) { _ in cont.resume() }
            task.observe(.failure) { snapshot in
                cont.resume(throwing: snapshot.error ?? SocialError.uploadFailed)
            }
        }
    }

    func uploadAndCreatePost(image: UIImage?,
                             videoURL: URL?,
                             caption: String,
                             place: PlaceSelection? = nil) async throws {
        let source: MediaDraft.Source
        if let image {
            source = .image(image)
        } else if let videoURL {
            source = .video(videoURL)
        } else {
            throw SocialError.uploadFailed
        }
        let draft = MediaDraft(source: source, place: place,
                               caption: caption.isEmpty ? nil : caption)
        try await uploadAndCreatePost(drafts: [draft])
    }

    /// Creates a post from 1…6 ordered media drafts, each with an optional
    /// place tag and caption. Uploads every item, mirrors item 0 to the
    /// top-level fields (back-compat + feed filter + Discover index), writes
    /// the `media` array, and optimistically prepends the post.
    /// `recipientUids` nil/empty = an "everyone" post (visible to all friends,
    /// Discover-eligible). A non-empty set restricts the post to those friends
    /// — the author is always added so they see their own restricted post, and
    /// the post is forced non-discoverable.
    func uploadAndCreatePost(drafts: [MediaDraft], recipientUids: [String]? = nil,
                             music: PostMusic? = nil) async throws {
        guard let authorUid = uid else { throw SocialError.notSignedIn }
        guard let username = profile?.username else { throw SocialError.needsUsername }
        guard !drafts.isEmpty, drafts.count <= 6 else { throw SocialError.uploadFailed }

        let isRestricted = (recipientUids?.isEmpty == false)
        // Materialize selected friends + author; the rule requires the author
        // present and the Q2 feed query is `recipientUids array-contains me`.
        let finalRecipients: [String] = isRestricted
            ? Array(Set((recipientUids ?? []) + [authorUid]))
            : []

        let postRef = db.collection("posts").document()
        let postId = postRef.documentID
        // Client `Timestamp` so `orderBy(createdAt)` includes the doc immediately.
        let createdAt = Timestamp(date: .now)
        // Device-local hour (0–23) at post time. The `onPostCreatePlaceVisit`
        // Cloud Function runs in UTC and can't recover local time from the
        // absolute `createdAt` instant, so stamp it here to drive the Night Owl
        // ("check in after 9 PM") achievement counter.
        let localHour = Calendar.current.component(.hour, from: createdAt.dateValue())
        // Device-local calendar day (YYYY-MM-DD) — drives the server-side
        // consecutive-day posting streak (Streak Keeper achievements).
        let localDayFormatter = DateFormatter()
        localDayFormatter.calendar = Calendar.current
        localDayFormatter.locale = Locale(identifier: "en_US_POSIX")
        localDayFormatter.dateFormat = "yyyy-MM-dd"
        let localDay = localDayFormatter.string(from: createdAt.dateValue())

        // Resolve each DISTINCT place once (sequential — usually 0-1 places;
        // dedup means a single findOrCreatePlace call even when photos share
        // a cafe, avoiding the concurrent-create race).
        var resolvedByKey: [String: (id: String, name: String)] = [:]
        for sel in dedupPlaceSelections(drafts.compactMap(\.place)) {
            resolvedByKey[placeKey(sel)] = try await resolvePlace(sel)
        }
        func resolved(_ sel: PlaceSelection?) -> (id: String, name: String)? {
            guard let sel else { return nil }
            return resolvedByKey[placeKey(sel)]
        }

        // Upload each item in order → build the media array. A thrown error
        // aborts BEFORE any doc is written, so no half-post lands (already-
        // uploaded blobs are orphaned but harmless). Each item's byte progress
        // is mapped into its 1/N slice so `uploadProgress` advances smoothly
        // across the whole post (drives the DI ring + non-DI pill).
        let itemCount = drafts.count
        func reportProgress(item i: Int, fraction frac: Double) {
            let overall = (Double(i) + min(max(frac, 0), 1)) / Double(itemCount)
            uploadProgress = overall
            UploadLiveActivityController.shared.update(progress: overall)
        }
        var media: [PostMedia] = []
        var firstImageForClassify: UIImage?
        for (i, draft) in drafts.enumerated() {
            let place = resolved(draft.place)
            let cap: String? = {
                guard let c = draft.caption, !c.isEmpty else { return nil }
                return String(c.prefix(25))
            }()
            switch draft.source {
            case .image(let image):
                // Prepare + JPEG-encode OFF the main actor — this is heavy
                // (full-res bitmap redraw + Core Image render + encode) and
                // `SocialService` is @MainActor, so doing it inline would block
                // the main thread right as the post-launch animation plays
                // (the cause of the intermittent stutter). Offloading keeps the
                // spring smooth.
                let prepared = await Task.detached(priority: .userInitiated) {
                    () -> (data: Data, processed: UIImage)? in
                    let processed = CameraCaptureProcessing.preparePhotoForUpload(image) ?? image
                    guard let data = processed.jpegData(compressionQuality: 0.82) else { return nil }
                    return (data, processed)
                }.value
                guard let prepared else { throw SocialError.uploadFailed }
                let data = prepared.data
                let processed = prepared.processed
                let ref = Storage.storage().reference().child("social/\(authorUid)/\(postId)_\(i).jpg")
                try await putDataTracked(data, to: ref) { frac in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let overall = (Double(i) + min(max(frac, 0), 1)) / Double(itemCount)
                        self.uploadProgress = overall
                        UploadLiveActivityController.shared.update(progress: overall)
                    }
                }
                let url = try await ref.downloadURL()
                media.append(PostMedia(type: "image", url: url.absoluteString,
                                       placeId: place?.id, placeName: place?.name, caption: cap))
                if firstImageForClassify == nil { firstImageForClassify = processed }
            case .video(let videoURL):
                let squareURL: URL = videoURL.lastPathComponent.contains("_sq")
                    ? videoURL
                    : ((try? await CameraCaptureProcessing.exportSquareVideo(from: videoURL)) ?? videoURL)
                let ref = Storage.storage().reference().child("social/\(authorUid)/\(postId)_\(i).mp4")
                try await putFileTracked(from: squareURL, to: ref) { frac in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let overall = (Double(i) + min(max(frac, 0), 1)) / Double(itemCount)
                        self.uploadProgress = overall
                        UploadLiveActivityController.shared.update(progress: overall)
                    }
                }
                let url = try await ref.downloadURL()
                let thumb = try? await generateVideoThumbnail(videoURL: squareURL,
                                                              postId: "\(postId)_\(i)", authorUid: authorUid)
                media.append(PostMedia(type: "video", url: url.absoluteString, thumbnailURL: thumb,
                                       placeId: place?.id, placeName: place?.name, caption: cap))
            }
            reportProgress(item: i, fraction: 1)
        }
        guard let first = media.first else { throw SocialError.uploadFailed }

        // Firestore payload: the media[] array + mirror of item 0 to the
        // top-level fields the feed filter / Discover index / legacy readers need.
        let mediaPayload: [[String: Any]] = media.map { m in
            var d: [String: Any] = ["type": m.type, "url": m.url]
            if let t = m.thumbnailURL { d["thumbnailURL"] = t }
            if let p = m.placeId { d["placeId"] = p }
            if let pn = m.placeName { d["placeName"] = pn }
            if let c = m.caption { d["caption"] = c }
            return d
        }
        var payload: [String: Any] = [
            "authorId": authorUid,
            "authorUsername": username,
            "caption": first.caption ?? "",
            "mediaType": first.type,
            "mediaURL": first.url,
            "createdAt": createdAt,
            "localHour": localHour,
            "localDay": localDay,
            "media": mediaPayload,
        ]
        if let t = first.thumbnailURL { payload["thumbnailURL"] = t }
        if let pid = first.placeId {
            payload["placeId"] = pid
            payload["placeName"] = first.placeName ?? ""
        }
        // Denormalized list of every DISTINCT place this post's photos tag —
        // not just item 0's. Lets the place-detail public/Trending fallback
        // (`fetchDiscoverablePostsAtPlace`) match a post via `array-contains`
        // when the place is only tagged in a secondary photo. Same formula as
        // the `onPostCreatePlaceVisit` Cloud Function and client `distinctPlaceIds`.
        let mediaPlaceIds = Array(Set(media.compactMap(\.placeId)))
        if !mediaPlaceIds.isEmpty { payload["mediaPlaceIds"] = mediaPlaceIds }
        // Audience gate. Always stamp `restricted` (so the Q1 `restricted == false`
        // feed query matches every new everyone-post). A restricted post carries
        // its recipients and is forced non-discoverable up front.
        payload["restricted"] = isRestricted
        if isRestricted {
            payload["recipientUids"] = finalRecipients
            payload["discoverable"] = false
        }
        // Optional attached song — one per post, stored as a nested map the feed
        // plays as background music. No Firestore-rule change needed (the posts
        // rules validate authorId/audience, not an exact field allowlist).
        if let music { payload["music"] = music.firestoreDict }

        // Optimistic feed insert (media-aware) so the caller's spinner stops now.
        prependOptimisticFeedPost(FriendPost(
            id: postId,
            authorId: authorUid,
            authorUsername: username,
            caption: first.caption ?? "",
            mediaType: first.type,
            mediaURL: first.url,
            thumbnailURL: first.thumbnailURL,
            createdAt: createdAt.dateValue(),
            placeId: first.placeId,
            placeName: first.placeName,
            restricted: isRestricted,
            recipientUids: finalRecipients,
            media: media,
            music: music
        ))

        // Fire-and-forget the doc write (SDK caches locally + retries) — the
        // detached Task lets the caller's spinner stop the moment the
        // optimistic prepend lands above, without awaiting the round-trip.
        let postRefCopy = postRef
        Task.detached {
            do {
                try await postRefCopy.setData(payload)
            } catch {
                #if DEBUG
                print("[SocialService] post setData failed: \(error.localizedDescription)")
                #endif
            }
        }

        // Background Discover classification on the first image (the bytes a
        // stranger would see). Skipped for video-only posts AND for restricted
        // posts — those are never discoverable, so there's nothing to classify
        // and we must not let the verdict patch flip `discoverable` true.
        if let img = firstImageForClassify, !isRestricted {
            let postRefForVerdict = postRef
            Task.detached(priority: .utility) {
                // Hold off ~1s so the Vision/CoreML classify doesn't hammer the
                // Neural Engine while the post-launch animation is still playing
                // (it shares the GPU with the SwiftUI render). The verdict only
                // affects Discover eligibility, so a brief delay is invisible.
                try? await Task.sleep(for: .seconds(1))
                let verdict = await PostClassifier.classify(img)
                #if DEBUG
                print("[Discover] post \(postId): faces=\(verdict.containsFaces) score=\(String(format: "%.2f", verdict.aestheticScore)) discoverable=\(verdict.discoverable)")
                #endif
                try? await postRefForVerdict.setData([
                    "discoverable": verdict.discoverable,
                    "aestheticScore": verdict.aestheticScore,
                    "containsFaces": verdict.containsFaces,
                ], merge: true)
            }
        }
    }

    /// Stable dedup key for a place selection (prefer DB id, then Google id,
    /// then name+coords) so the same place resolves once per post.
    private func placeKey(_ sel: PlaceSelection) -> String {
        if let id = sel.id, !sel.isNew { return "id:\(id)" }
        if let g = sel.googlePlaceId { return "g:\(g)" }
        return "n:\(sel.name.lowercased())|\(sel.lat),\(sel.lng)"
    }

    private func dedupPlaceSelections(_ sels: [PlaceSelection]) -> [PlaceSelection] {
        var seen = Set<String>()
        var out: [PlaceSelection] = []
        for s in sels where seen.insert(placeKey(s)).inserted { out.append(s) }
        return out
    }

    /// Calls the `findOrCreatePlace` Cloud Function — server-side dedup ensures
    /// the same place isn't created twice across users. Returns the resolved
    /// (placeId, placeName) for stamping on the post.
    private func resolvePlace(_ sel: PlaceSelection) async throws -> (id: String, name: String) {
        // Fast path: user picked an existing DB row from the picker — we
        // already have a stable placeId, so skip the cloud round-trip.
        if let existingId = sel.id, !sel.isNew {
            return (existingId, sel.name)
        }

        var lat = sel.lat
        var lng = sel.lng
        // User-added-by-name flow: no coords yet, fall back to current location.
        if lat == 0 && lng == 0 {
            if let coord = await LocationProvider.shared.currentCoordinate() {
                lat = coord.latitude
                lng = coord.longitude
            } else {
                throw SocialError.uploadFailed
            }
        }
        var payload: [String: Any] = [
            "name": sel.name,
            "type": sel.type.rawValue,
            "lat": lat,
            "lng": lng,
        ]
        if let gid = sel.googlePlaceId {
            payload["googlePlaceId"] = gid
        }
        // Pass the Google formatted address so the place doc can store it
        // (used later to derive a city label without reverse-geocoding).
        if let address = sel.address, !address.isEmpty {
            payload["address"] = address
        }
        let callable = Functions.functions().httpsCallable("findOrCreatePlace")
        let result = try await callable.call(payload)
        guard let dict = result.data as? [String: Any],
              let id = dict["placeId"] as? String,
              let name = dict["placeName"] as? String else {
            throw SocialError.uploadFailed
        }
        return (id, name)
    }

    private func generateVideoThumbnail(videoURL: URL, postId: String, authorUid: String) async throws -> String {
        let asset = AVURLAsset(url: videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let t = CMTime(seconds: 0.05, preferredTimescale: 600)
        let cg = try await gen.image(at: t).image
        let ui = UIImage(cgImage: cg)
        guard let data = ui.jpegData(compressionQuality: 0.75) else { throw SocialError.uploadFailed }
        let path = "social/\(authorUid)/\(postId)_thumb.jpg"
        let ref = Storage.storage().reference().child(path)
        _ = try await ref.putDataAsync(data)
        return try await ref.downloadURL().absoluteString
    }
}
