import AuthenticationServices
import CryptoKit
import FirebaseAuth
import Foundation
import Security
import UIKit

/// Spotify connection for the "soundtrack your post" feature.
///
/// The POSTER signs in (OAuth Authorization Code + PKCE — no client secret is
/// stored in the app) so they can search/browse their music and pick a track.
/// We only ever read metadata + the 30-second `preview_url`; we never call any
/// playback/streaming endpoint. Viewers never need to connect — the chosen
/// track's `preview_url` is stored on the post and played by a plain `AVPlayer`.
///
/// Lifecycle mirrors the other services (`start(for:)` / `reset()`), created as
/// `@State` in `WanderyEntryView` and threaded down. Tokens live in the
/// device-local keychain (`SpotifyTokenStore`), so a Firebase sign-out does NOT
/// drop the Spotify link — only `disconnect()` clears it.
@MainActor
@Observable
final class SpotifyAuthService {

    // MARK: Published state
    private(set) var isConnected = false
    var isConnecting = false
    private(set) var displayName: String?
    var lastError: String?

    /// True once a real Client ID is present (Secrets.xcconfig → Info.plist).
    /// The composer hides "Add music" when false instead of failing on tap.
    var isConfigured: Bool { Self.clientID != nil }

    // MARK: Config
    private static let redirectURI = "cafehunter-spotify://callback"
    private static let callbackScheme = "cafehunter-spotify"
    private static let scopes =
        "user-read-private playlist-read-private playlist-read-collaborative user-library-read user-read-currently-playing user-read-playback-state"
    private static let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!
    private static let apiBase = "https://api.spotify.com/v1"

    /// Resolved Client ID, or nil if the xcconfig var was never filled in
    /// (still the placeholder, or the `$(SPOTIFY_CLIENT_ID)` literal because
    /// Secrets.xcconfig is missing the key).
    private static var clientID: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String,
              !id.isEmpty,
              id != "REPLACE_WITH_YOUR_SPOTIFY_CLIENT_ID",
              !id.hasPrefix("$(") else { return nil }
        return id
    }

    private var tokens: SpotifyStoredTokens?
    private var authSession: ASWebAuthenticationSession?
    private let presentationProvider = SpotifyPresentationProvider()

    // MARK: Lifecycle

    /// Load any persisted tokens from the keychain. Called from
    /// `ContentView.task(id: uid)` alongside the other services.
    func start(for user: FirebaseAuth.User?) {
        guard user != nil else { return }
        if let stored = SpotifyTokenStore.load() {
            tokens = stored
            isConnected = true
            Task { await fetchDisplayName() }
        }
    }

    /// Clears in-memory state on Firebase sign-out. Does NOT delete tokens —
    /// the next `start()` reloads them so the Spotify link survives a re-login.
    func reset() {
        tokens = nil
        isConnected = false
        displayName = nil
        lastError = nil
    }

    // MARK: Connect / disconnect

    func connect() async throws {
        guard let clientID = Self.clientID else { throw SpotifyError.notConfigured }
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        let verifier = Self.randomURLSafe(byteCount: 64)
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomURLSafe(byteCount: 16)

        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            .init(name: "scope", value: Self.scopes),
        ]
        guard let authURL = comps.url else { throw SpotifyError.badRequest }

        let callbackURL: URL
        do {
            callbackURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: Self.callbackScheme
                ) { url, error in
                    if let url {
                        cont.resume(returning: url)
                    } else {
                        cont.resume(throwing: error ?? SpotifyError.cancelled)
                    }
                }
                session.presentationContextProvider = presentationProvider
                session.prefersEphemeralWebBrowserSession = false
                authSession = session
                if !session.start() { cont.resume(throwing: SpotifyError.cannotStart) }
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            authSession = nil
            throw SpotifyError.cancelled
        }
        authSession = nil

        // Validate state (CSRF) and pull the authorization code.
        guard let cb = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let items = cb.queryItems,
              items.first(where: { $0.name == "state" })?.value == state else {
            throw SpotifyError.authFailed
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw SpotifyError.cancelled   // e.g. error=access_denied
        }

        do {
            try await exchangeCode(code, verifier: verifier, clientID: clientID)
        } catch {
            lastError = SpotifyError.authFailed.errorDescription
            throw SpotifyError.authFailed
        }
        isConnected = true
        lastError = nil
        await fetchDisplayName()
    }

    func disconnect() {
        SpotifyTokenStore.delete()
        tokens = nil
        displayName = nil
        isConnected = false
        lastError = nil
    }

    // MARK: Web API (poster-only)

    /// Catalog track search — the primary picker. In DEBUG this also logs the
    /// `preview_url` fill rate (the project's go/no-go spike: if most results
    /// have a null preview, the playback approach won't work).
    func search(query: String) async throws -> [SpotifyTrack] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let data = try await authorizedData(path: "/search", query: [
            .init(name: "q", value: q),
            .init(name: "type", value: "track"),
            .init(name: "limit", value: "25"),
        ])
        let resp = try JSONDecoder().decode(SpotifySearchResponse.self, from: data)
        let tracks = resp.tracks?.items ?? []
        #if DEBUG
        let withPreview = tracks.filter { ($0.preview_url?.isEmpty == false) }.count
        print("🎵 [preview_url spike] search \"\(q)\": \(withPreview)/\(tracks.count) tracks playable")
        #endif
        return tracks
    }

    func myPlaylists() async throws -> [SpotifyPlaylist] {
        let data = try await authorizedData(path: "/me/playlists",
                                            query: [.init(name: "limit", value: "50")])
        return try JSONDecoder().decode(SpotifyPaging<SpotifyPlaylist>.self, from: data).items
    }

    func playlistTracks(id: String) async throws -> [SpotifyTrack] {
        let data = try await authorizedData(path: "/playlists/\(id)/tracks", query: [
            .init(name: "limit", value: "100"),
            .init(name: "fields",
                  value: "items(track(id,name,preview_url,artists(name),album(name,images)))"),
        ])
        let paging = try JSONDecoder().decode(SpotifyPaging<SpotifyPlaylistItem>.self, from: data)
        return paging.items.compactMap(\.track)
    }

    func savedTracks() async throws -> [SpotifyTrack] {
        let data = try await authorizedData(path: "/me/tracks",
                                            query: [.init(name: "limit", value: "50")])
        let paging = try JSONDecoder().decode(SpotifyPaging<SpotifySavedTrackItem>.self, from: data)
        return paging.items.compactMap(\.track)
    }

    /// The user's currently-playing (or paused) track, or nil when nothing is
    /// active / the content isn't a song (ad, podcast). Throws `SpotifyError.api`
    /// on auth/permission failures so the composer can offer Reconnect (401) or
    /// degrade (403). `authorizedData` already DEBUG-logs the HTTP status.
    func currentlyPlaying() async throws -> SpotifyTrack? {
        let data = try await authorizedData(path: "/me/player/currently-playing",
                                            query: [.init(name: "additional_types", value: "track")])
        // HTTP 204 (nothing active) is a 2xx with an empty body — not an error.
        guard !data.isEmpty else { return nil }
        let resp = try JSONDecoder().decode(SpotifyCurrentlyPlaying.self, from: data)
        guard resp.currently_playing_type == "track", let item = resp.item else { return nil }
        return item   // playing OR paused — caller decides what to show
    }

    private func fetchDisplayName() async {
        guard let data = try? await authorizedData(path: "/me", query: []),
              let user = try? JSONDecoder().decode(SpotifyUser.self, from: data) else { return }
        displayName = (user.display_name?.isEmpty == false) ? user.display_name : user.id
    }

    // MARK: Token plumbing

    private func exchangeCode(_ code: String, verifier: String, clientID: String) async throws {
        let body = Self.formEncode([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
        let token = try await postToken(body)
        persist(SpotifyStoredTokens(
            accessToken: token.access_token,
            refreshToken: token.refresh_token ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expires_in))
        ))
    }

    /// Refresh the access token. On `invalid_grant` (revoked/expired refresh
    /// token) the connection is dropped so the UI reflects "disconnected".
    private func refresh(clientID: String) async throws {
        guard let refreshToken = tokens?.refreshToken, !refreshToken.isEmpty else {
            throw SpotifyError.notConnected
        }
        let body = Self.formEncode([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        do {
            let token = try await postToken(body)
            persist(SpotifyStoredTokens(
                accessToken: token.access_token,
                // Spotify may omit a fresh refresh token — keep the existing one.
                refreshToken: token.refresh_token ?? refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(token.expires_in))
            ))
        } catch {
            disconnect()
            throw SpotifyError.notConnected
        }
    }

    private func postToken(_ body: String) async throws -> SpotifyTokenResponse {
        var req = URLRequest(url: Self.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw SpotifyError.authFailed
        }
        let token = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        #if DEBUG
        print("🎵 [Spotify] token granted scopes: \(token.scope ?? "<none>")")
        #endif
        return token
    }

    private func persist(_ newTokens: SpotifyStoredTokens) {
        tokens = newTokens
        SpotifyTokenStore.save(newTokens)
    }

    private func validAccessToken() async throws -> String {
        guard let clientID = Self.clientID else { throw SpotifyError.notConfigured }
        guard let current = tokens else { throw SpotifyError.notConnected }
        if current.expiresAt.timeIntervalSinceNow < 60 {
            try await refresh(clientID: clientID)
        }
        guard let token = tokens?.accessToken else { throw SpotifyError.notConnected }
        return token
    }

    /// Authorized GET against the Web API with refresh-on-401 (retry once).
    private func authorizedData(path: String, query: [URLQueryItem]) async throws -> Data {
        func request(_ token: String) throws -> URLRequest {
            var comps = URLComponents(string: Self.apiBase + path)!
            if !query.isEmpty { comps.queryItems = query }
            guard let url = comps.url else { throw SpotifyError.badRequest }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return req
        }

        // A genuine transport failure (offline, DNS, timeout) → `.requestFailed`,
        // distinct from a non-2xx HTTP response (handled below as `.api`).
        func fetch(_ req: URLRequest) async throws -> (Data, URLResponse) {
            do { return try await URLSession.shared.data(for: req) }
            catch { throw SpotifyError.requestFailed }
        }

        var token = try await validAccessToken()
        var (data, resp) = try await fetch(request(token))

        if let http = resp as? HTTPURLResponse, http.statusCode == 401,
           let clientID = Self.clientID {
            try await refresh(clientID: clientID)
            token = try await validAccessToken()
            (data, resp) = try await fetch(request(token))
        }

        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if status == 401 { isConnected = false }
            let apiMessage = (try? JSONDecoder().decode(SpotifyAPIError.self, from: data))?.error.message
            #if DEBUG
            print("🎵 [Spotify] \(path) → HTTP \(status): \(apiMessage ?? "<no body>")")
            #endif
            throw SpotifyError.api(status: status, message: apiMessage)
        }
        return data
    }

    // MARK: PKCE helpers

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}

// MARK: - Errors

enum SpotifyError: LocalizedError {
    case notConfigured, notConnected, cancelled, authFailed, requestFailed, cannotStart, badRequest
    /// A non-2xx Web API response, carrying the real HTTP status (and Spotify's
    /// error message when present) so the UI can react — e.g. prompt a reconnect
    /// on a 401/403 instead of showing a flat "couldn't reach" message.
    case api(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Spotify isn't set up yet. Add your Client ID to Secrets.xcconfig."
        case .notConnected: return "You're not connected to Spotify."
        case .cancelled:    return "No worries, cancelled that one."
        case .authFailed:   return "Spotify sign-in didn't go through. Give it another shot 🎵"
        case .requestFailed: return "Couldn't reach Spotify. Try again in a moment."
        case .cannotStart:  return "Couldn't open the Spotify sign-in screen."
        case .badRequest:   return "Something went wrong talking to Spotify."
        case .api(let status, _):
            switch status {
            case 401:  return "Your Spotify session expired. Tap Reconnect."
            // 403 here is an app-access limit (Spotify restricts some reads for
            // apps in Development Mode), not a scope/session problem — so
            // reconnecting won't help.
            case 403:  return "Spotify won't share what's playing for this app right now."
            case 404:  return "That playlist isn't available to open."
            case 429:  return "Spotify is busy right now — try again in a moment."
            default:   return "Couldn't reach Spotify. Try again in a moment."
            }
        }
    }

    /// True when the right remedy is a fresh Spotify authorization (refreshes an
    /// expired session) rather than a plain retry. A 403 is deliberately
    /// excluded: scopes are already complete, so reconnecting can't fix it.
    var needsReconnect: Bool {
        switch self {
        case .notConnected:            return true
        case .api(let status, _):      return status == 401
        default:                       return false
        }
    }
}

// MARK: - Redirect inbox (belt-and-suspenders)

/// `ASWebAuthenticationSession` normally delivers the PKCE callback through its
/// own completion handler, so `.onOpenURL` won't fire for the redirect. This
/// singleton exists only so `CafeHunterApp`'s `.onOpenURL` has somewhere to hand
/// a `cafehunter-spotify://` URL if iOS ever routes it to the scene instead —
/// and so it never falls through to the Google/Firebase handlers.
@MainActor
final class SpotifyRedirectInbox {
    static let shared = SpotifyRedirectInbox()
    private init() {}
    var onCallback: ((URL) -> Bool)?
    @discardableResult
    func consume(_ url: URL) -> Bool { onCallback?(url) ?? false }
}

// MARK: - Presentation anchor

private final class SpotifyPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
        }
    }
}

// MARK: - Token persistence (device-local keychain)

private struct SpotifyStoredTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

/// Device-local keychain store for Spotify OAuth tokens. Unlike `Keychain`
/// (which iCloud-syncs the E2EE identity key), these are bound to this device
/// only (`…ThisDeviceOnly`, non-synchronizable) — OAuth tokens shouldn't roam.
private enum SpotifyTokenStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "TechVision.CafeHunter") + ".spotify"
    private static let account = "oauth.tokens"

    static func save(_ tokens: SpotifyStoredTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> SpotifyStoredTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let tokens = try? JSONDecoder().decode(SpotifyStoredTokens.self, from: data)
        else { return nil }
        return tokens
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
