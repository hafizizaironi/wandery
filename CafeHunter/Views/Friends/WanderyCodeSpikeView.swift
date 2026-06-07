import SwiftUI
import UIKit
import Photos

/// The user's Wandery Profile Code. Two tabs:
///  • My Code — your circular friend-code full-bleed on cream, with a "hold
///    still to scan" freeze and Share / Save. Mints your permanent code on
///    open and keeps a short "presenting" window alive while shown.
///  • Scan — point at a friend's code to add them (instant in person, else a
///    friend request).
struct WanderyCodeSpikeView: View {
    var displayName: String
    var username: String?
    var photoURL: String?
    var onClose: () -> Void

    // The mark + My Code screen live on paper cream (not the app surface).
    private static let paper = Color(hex: "#f0e9d8")

    @State private var tab = 0
    @State private var holdStill = false

    // Scan state
    @State private var decoded: WanderyCodeDetector.Result?
    @State private var scanAttempt = 0
    @State private var resolveResult: WanderyCodeService.ResolveResult?

    // Share / Save
    @State private var shareImage: UIImage?
    @State private var showShare = false
    @State private var saveStatus: String?

    // Backend identity: the user's permanent account id.
    @State private var codeService = WanderyCodeService()
    @State private var realAccountId: UInt64?
    @State private var codeLoadFailed = false
    @State private var photo: UIImage?

    /// Avatar letter for the locket (from username, else display name).
    private var initial: String {
        let name = (username?.isEmpty == false) ? username! : displayName
        return name.first.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                Text("My Code").tag(0)
                Text("Scan").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            if tab == 0 { myCodeTab } else { scanTab }
        }
        .background(Self.paper.ignoresSafeArea())
        .sheet(isPresented: $showShare) {
            if let img = shareImage { ShareSheet(items: [img]) }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Button("Close", action: onClose)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text("Wandery Profile Code")
                .font(.subheadline).bold()
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Text("Close").font(.subheadline).foregroundStyle(.clear).accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - My Code tab (full-bleed, no card)

    private var myCodeTab: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            // Code floats directly on the cream page — its paper quiet-zone
            // matches the background, so there's no card.
            codeArea

            VStack(spacing: 4) {
                Text(displayName)
                    .font(.system(size: 40, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(AppTheme.textPrimary)
                if let username, !username.isEmpty {
                    Text("@\(username)")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(.top, 8)

            Text("Point a friend's camera at this to add them on Wandery.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 48)
                .padding(.top, 10)

            // Freeze the idle spin to a still, scan-stable code before scanning.
            if realAccountId != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { holdStill.toggle() }
                } label: {
                    Label(holdStill ? "Resume animation" : "Hold still to scan",
                          systemImage: holdStill ? "play.circle" : "pause.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.cafeAccent)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }

            Spacer()

            if let saveStatus {
                Text(saveStatus)
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                    .transition(.opacity)
                    .padding(.bottom, 4)
            }
            bottomButtons
                .disabled(realAccountId == nil)
                .opacity(realAccountId == nil ? 0.45 : 1)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .task {
            await loadCode()
            // Presenting heartbeat while My Code is on screen. Cancelled on tab
            // switch / dismiss, so the 60s window lapses when you stop showing.
            while !Task.isCancelled, realAccountId != nil {
                await codeService.beginPresenting()
                try? await Task.sleep(for: .seconds(45))
            }
        }
        .task { await loadPhoto() }
    }

    @ViewBuilder
    private var codeArea: some View {
        if let id = realAccountId {
            withAvatar(WanderyCodeView(accountId: id, animated: !holdStill, centerInitial: initial), size: 300)
        } else {
            ZStack {
                if codeLoadFailed {
                    VStack(spacing: 10) {
                        Text("Couldn't load your code.")
                            .font(.footnote).foregroundStyle(AppTheme.textSecondary)
                        Button("Retry") { Task { await loadCode() } }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.cafeAccent)
                    }
                } else {
                    ProgressView().tint(AppTheme.cafeAccent)
                }
            }
            .frame(width: 300, height: 300)
        }
    }

    /// Overlays the user's profile photo into the locket (a quiet zone — no
    /// data). Until it loads (or if there's no photo) the drawn initial shows.
    @ViewBuilder
    private func withAvatar<Base: View>(_ base: Base, size: CGFloat) -> some View {
        ZStack {
            base
            if let photo {
                let d = size * CGFloat(2 * WanderyCodeGeometry.locketR / WanderyCodeGeometry.box)
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: d, height: d)
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
    }

    private var bottomButtons: some View {
        HStack(spacing: 12) {
            Button {
                shareImage = makeImage()
                showShare = shareImage != nil
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.cafeAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.cafeAccent.opacity(0.08))
                    .clipShape(.rect(cornerRadius: 16))
                    .overlay { RoundedRectangle(cornerRadius: 16).stroke(AppTheme.cafeAccent.opacity(0.4), lineWidth: 1) }
            }
            .buttonStyle(.plain)

            Button { saveCode() } label: {
                Label("Save Code", systemImage: "square.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(hex: "#a07522"))
                    .clipShape(.rect(cornerRadius: 16))
                    .shadow(color: Color(hex: "#a07522").opacity(0.32), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Scan tab

    private var scanTab: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            WanderyCodeScannerView(
                onDecode: { result in
                    decoded = result
                    resolveResult = nil
                    Task { resolveResult = await codeService.resolve(accountId: result.accountId) }
                }
            )
            .id(scanAttempt)
            .ignoresSafeArea()

            if decoded == nil { RadialPulse().frame(width: 300, height: 300) }

            VStack {
                Spacer()
                if let d = decoded {
                    resultBanner(d)
                } else {
                    Text("Point at a friend's Wandery code")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(.black.opacity(0.35))
                        .clipShape(Capsule())
                }
            }
            .padding(20)
        }
    }

    private func resultBanner(_ d: WanderyCodeDetector.Result) -> some View {
        VStack(spacing: 14) {
            if let r = resolveResult {
                if let p = r.profile {
                    AvatarView(urlString: p.photoURL, name: p.username ?? p.displayName, size: 84, stroke: .subtle)
                    VStack(spacing: 3) {
                        if let name = p.displayName, !name.isEmpty {
                            Text(name).font(.title3.weight(.semibold)).foregroundStyle(.white)
                        }
                        Text("@\(p.username ?? "wanderer")")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    if p.cafes > 0 || p.stalls > 0 || p.restaurants > 0 {
                        HStack(spacing: 10) {
                            if p.cafes > 0 { huntChip(p.cafes, "cafés") }
                            if p.restaurants > 0 { huntChip(p.restaurants, "restaurants") }
                            if p.stalls > 0 { huntChip(p.stalls, "stalls") }
                        }
                    }
                    messagePill(for: r.outcome)
                } else {
                    Image(systemName: errorIcon(for: r.outcome))
                        .font(.largeTitle).foregroundStyle(.white.opacity(0.85))
                    messagePill(for: r.outcome)
                }
            } else {
                ProgressView().tint(.white)
                Text("Connecting…").font(.subheadline).foregroundStyle(.white.opacity(0.8))
            }

            Button {
                decoded = nil
                resolveResult = nil
                scanAttempt += 1
            } label: {
                Text("Scan again")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22).padding(.vertical, 11)
                    .background(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private func huntChip(_ n: Int, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text("\(n)").font(.subheadline.weight(.bold)).foregroundStyle(.white)
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.white.opacity(0.12))
        .clipShape(Capsule())
    }

    private func messagePill(for outcome: WanderyCodeService.ResolveOutcome) -> some View {
        let m = Self.message(for: outcome)
        return Text(m.0)
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(m.1)
    }

    private static func message(for outcome: WanderyCodeService.ResolveOutcome) -> (String, Color) {
        switch outcome {
        case .added:          return ("You're hunting buddies now!", AppTheme.stallAccent)
        case .alreadyFriends: return ("Already hunting buddies", .white)
        case .requested:      return ("Friend request sent — waiting on them", AppTheme.cafeAccent)
        case .isSelf:         return ("That's your own code", .white)
        case .notFound:       return ("That code isn't active.", .orange)
        case .blocked:        return ("Can't add this person.", .orange)
        case .failed(let msg): return (msg, .orange)
        }
    }

    private func errorIcon(for outcome: WanderyCodeService.ResolveOutcome) -> String {
        switch outcome {
        case .notFound: return "questionmark.circle"
        case .blocked:  return "hand.raised"
        case .isSelf:   return "person.crop.circle"
        default:        return "exclamationmark.triangle"
        }
    }

    // MARK: - Actions

    private func loadCode() async {
        do {
            realAccountId = try await codeService.ensureCode()
            codeLoadFailed = false
        } catch {
            codeLoadFailed = true
        }
    }

    private func loadPhoto() async {
        guard photo == nil, let s = photoURL, let url = URL(string: s) else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let img = UIImage(data: data) {
            photo = img
        }
    }

    @MainActor
    private func makeImage() -> UIImage? {
        guard let id = realAccountId, let enc = WanderyCodec()?.encode(accountId: id) else { return nil }
        let renderer = ImageRenderer(content:
            withAvatar(WanderyCodeCanvas(encoded: enc, centerInitial: initial), size: 600)
                .background(Self.paper))
        renderer.scale = 3
        return renderer.uiImage
    }

    private func saveCode() {
        guard let img = makeImage() else { return }
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await flashSave("Allow Photos access in Settings to save.")
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: img)
                }
                await flashSave("Saved to Photos ✓")
            } catch {
                await flashSave("Couldn't save.")
            }
        }
    }

    @MainActor
    private func flashSave(_ message: String) async {
        withAnimation { saveStatus = message }
        try? await Task.sleep(for: .seconds(2.5))
        withAnimation { saveStatus = nil }
    }
}

/// Expanding, fading concentric rings — a sonar-style radial pulse used as the
/// scan reticle.
private struct RadialPulse: View {
    var color: Color = .white
    var maxDiameter: CGFloat = 300
    private let count = 2
    private let period = 4.0

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().fill(color.opacity(0.06)).frame(width: 64, height: 64)
                ForEach(0..<count, id: \.self) { i in
                    let p = ((t / period) + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(color.opacity((1 - p) * 0.45), lineWidth: 2)
                        .frame(width: maxDiameter * p, height: maxDiameter * p)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// Minimal UIActivityViewController bridge.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
