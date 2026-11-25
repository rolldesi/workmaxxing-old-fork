import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftUI

/// Spotify Web API for search and the queue (adding to the queue needs Premium).
/// Sign-in is OAuth with PKCE against the user's own developer app, so no
/// client secret exists; the refresh token lives in the Keychain.
@MainActor
final class SpotifyWebAPI: NSObject, ObservableObject {
    static let shared = SpotifyWebAPI()
    static let callbackScheme = "cmux-spotify"
    static let redirectURI = "cmux-spotify://callback"
    private static let clientIdKey = "cmuxFork.spotify.clientId"
    private static let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing"

    struct Track: Identifiable, Hashable {
        let id: String
        let uri: String
        let name: String
        let artists: String
        let imageURL: URL?
    }

    @Published var clientId: String {
        didSet { UserDefaults.standard.set(clientId, forKey: Self.clientIdKey) }
    }
    @Published private(set) var isSignedIn: Bool
    @Published private(set) var searchResults: [Track] = []
    @Published private(set) var queue: [Track] = []
    @Published private(set) var lastError: String?

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var authSession: ASWebAuthenticationSession?

    override init() {
        clientId = UserDefaults.standard.string(forKey: Self.clientIdKey) ?? ""
        isSignedIn = SpotifyKeychain.readRefreshToken() != nil
        super.init()
    }

    // MARK: Sign-in

    func signIn() {
        let trimmedClientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientId.isEmpty else { return }
        let verifier = Self.randomURLSafeString(byteCount: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: trimmedClientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: Self.scopes),
        ]
        guard let url = components?.url else { return }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { callback, error in
            let code = callback.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "code" }?.value
            let failure = error?.localizedDescription
            Task { @MainActor in
                let api = SpotifyWebAPI.shared
                api.authSession = nil
                guard let code else {
                    api.lastError = failure ?? String(localized: "spotify.api.signInCancelled", defaultValue: "Spotify sign-in was cancelled.")
                    return
                }
                await api.exchange(code: code, verifier: verifier)
            }
        }
        session.presentationContextProvider = self
        authSession = session
        session.start()
    }

    func signOut() {
        SpotifyKeychain.deleteRefreshToken()
        accessToken = nil
        isSignedIn = false
        searchResults = []
        queue = []
    }

    private func exchange(code: String, verifier: String) async {
        await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientId.trimmingCharacters(in: .whitespacesAndNewlines),
            "code_verifier": verifier,
        ])
    }

    private func requestToken(_ form: [String: String]) async {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String else {
                lastError = Self.errorMessage(data) ?? String(localized: "spotify.api.tokenFailed", defaultValue: "Spotify sign-in failed.")
                if form["grant_type"] == "refresh_token" { signOut() }
                return
            }
            accessToken = token
            accessTokenExpiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
            if let refresh = json["refresh_token"] as? String { SpotifyKeychain.writeRefreshToken(refresh) }
            let wasSignedIn = isSignedIn
            isSignedIn = true
            lastError = nil
            if !wasSignedIn { SpotifyModel.shared.refresh() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func validAccessToken() async -> String? {
        if let accessToken, accessTokenExpiry > Date().addingTimeInterval(60) { return accessToken }
        guard let refresh = SpotifyKeychain.readRefreshToken() else {
            isSignedIn = false
            return nil
        }
        await requestToken([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientId.trimmingCharacters(in: .whitespacesAndNewlines),
        ])
        return accessToken
    }

    // MARK: Search and queue

    func search(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchResults = []; return }
        guard let data = await call("GET", "/search", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: "25"),
        ]) else { return }
        let page = try? JSONDecoder().decode(SearchJSON.self, from: data)
        searchResults = page?.tracks.items.compactMap(\.track) ?? []
    }

    func refreshQueue() async {
        guard let data = await call("GET", "/me/player/queue") else { return }
        let page = try? JSONDecoder().decode(QueueJSON.self, from: data)
        queue = page?.queue.compactMap(\.track) ?? []
    }

    /// Appends to the playing queue (Spotify allows this for Premium only).
    func addToQueue(_ track: Track) async {
        _ = await call("POST", "/me/player/queue", query: [URLQueryItem(name: "uri", value: track.uri)])
        await refreshQueue()
    }

    // MARK: Playback

    struct PlaybackState {
        struct Item {
            let name: String
            let artists: String
            let imageURL: URL?
            let durationMs: Int
        }
        let isPlaying: Bool
        let progressMs: Int
        let shuffle: Bool
        let repeatMode: String
        let volume: Int?
        let item: Item?
    }

    /// What is playing on the user's account; `.some(nil)` when no device is
    /// active, nil when the request failed.
    func playbackState() async -> PlaybackState?? {
        guard let data = await call("GET", "/me/player") else { return nil }
        guard !data.isEmpty, let player = try? JSONDecoder().decode(PlayerJSON.self, from: data) else { return .some(nil) }
        let item = player.item.map { json in
            PlaybackState.Item(
                name: json.name,
                artists: (json.artists ?? []).map(\.name).joined(separator: ", "),
                imageURL: (json.album?.images?.first?.url ?? json.images?.first?.url).flatMap(URL.init(string:)),
                durationMs: json.duration_ms ?? 0
            )
        }
        return .some(PlaybackState(
            isPlaying: player.is_playing,
            progressMs: player.progress_ms ?? 0,
            shuffle: player.shuffle_state ?? false,
            repeatMode: player.repeat_state ?? "off",
            volume: player.device?.volume_percent,
            item: item
        ))
    }

    /// A `/me/player` command (play, pause, next, shuffle…); true when accepted.
    @discardableResult
    func player(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async -> Bool {
        await call(
            method,
            "/me/player" + path,
            query: query.map { URLQueryItem(name: $0.key, value: $0.value) },
            body: body
        ) != nil
    }

    /// The active Connect device, else a computer (this Mac's Spotify), else any.
    func playbackDevice() async -> String? {
        guard let data = await call("GET", "/me/player/devices"),
              let page = try? JSONDecoder().decode(DevicesJSON.self, from: data) else { return nil }
        let devices = page.devices.filter { $0.id != nil && $0.is_restricted != true }
        return (devices.first { $0.is_active } ?? devices.first { $0.type == "Computer" } ?? devices.first)?.id
    }

    private func call(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async -> Data? {
        guard let token = await validAccessToken() else { return nil }
        var components = URLComponents(string: "https://api.spotify.com/v1" + path)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if method != "GET" {
            // Spotify rejects bodiless PUT/POST without a length.
            request.httpBody = Data()
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                lastError = Self.errorMessage(data)
                    ?? String(format: String(localized: "spotify.api.httpError", defaultValue: "Spotify returned error %d."), status)
                return nil
            }
            lastError = nil
            return data
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: Helpers

    private static func errorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any] { return error["message"] as? String }
        return json["error_description"] as? String ?? json["error"] as? String
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct TrackJSON: Decodable {
        struct Named: Decodable { let name: String }
        struct Image: Decodable { let url: String }
        struct Album: Decodable { let images: [Image]? }
        let id: String?
        let uri: String
        let name: String
        let duration_ms: Int?
        let artists: [Named]?
        let album: Album?
        let images: [Image]?

        var track: Track? {
            guard let id else { return nil }
            let image = album?.images?.last?.url ?? images?.last?.url
            return Track(
                id: id,
                uri: uri,
                name: name,
                artists: (artists ?? []).map(\.name).joined(separator: ", "),
                imageURL: image.flatMap(URL.init(string:))
            )
        }
    }

    private struct SearchJSON: Decodable {
        struct Page: Decodable { let items: [TrackJSON] }
        let tracks: Page
    }

    private struct QueueJSON: Decodable {
        let queue: [TrackJSON]
    }

    private struct PlayerJSON: Decodable {
        struct Device: Decodable { let volume_percent: Int? }
        let is_playing: Bool
        let progress_ms: Int?
        let shuffle_state: Bool?
        let repeat_state: String?
        let device: Device?
        let item: TrackJSON?
    }

    private struct DevicesJSON: Decodable {
        struct Device: Decodable {
            let id: String?
            let is_active: Bool
            let is_restricted: Bool?
            let type: String
        }
        let devices: [Device]
    }
}

extension SpotifyWebAPI: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow() }
    }
}

/// The Spotify refresh token in the login Keychain.
private enum SpotifyKeychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "cmuxFork.spotify",
        kSecAttrAccount as String: "refreshToken",
    ]

    static func readRefreshToken() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func writeRefreshToken(_ token: String) {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func deleteRefreshToken() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Search and queue under the Spotify player when its tab is large enough.
struct SpotifyLibraryView: View {
    @ObservedObject private var api = SpotifyWebAPI.shared
    @ObservedObject private var player = SpotifyModel.shared
    @State private var showsQueue = false
    @State private var query = ""
    @State private var draftClientId = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if api.clientId.isEmpty {
                setup
            } else if !api.isSignedIn {
                Button(String(localized: "spotify.api.connect", defaultValue: "Connect Spotify Account"), action: api.signIn)
            } else {
                Picker("", selection: $showsQueue) {
                    Text(String(localized: "spotify.api.search", defaultValue: "Search")).tag(false)
                    Text(String(localized: "spotify.api.queue", defaultValue: "Queue")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if showsQueue {
                    trackList(api.queue, showsAdd: false)
                        .task { await api.refreshQueue() }
                } else {
                    TextField(String(localized: "spotify.api.searchPlaceholder", defaultValue: "Search songs"), text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await api.search(query) } }
                    trackList(api.searchResults, showsAdd: true)
                }
            }
            if let error = api.lastError {
                Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "spotify.api.setup", defaultValue: "Paste your Spotify app's Client ID to turn on search and the queue. Its redirect URI must be cmux-spotify://callback."))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            HStack {
                TextField(String(localized: "spotify.api.clientId", defaultValue: "Client ID"), text: $draftClientId)
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "spotify.api.save", defaultValue: "Save")) {
                    api.clientId = draftClientId.trimmingCharacters(in: .whitespacesAndNewlines)
                    api.signIn()
                }
                .disabled(draftClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func trackList(_ tracks: [SpotifyWebAPI.Track], showsAdd: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                    HStack(spacing: 8) {
                        AsyncImage(url: track.imageURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.white.opacity(0.08)
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.name).font(.callout).lineLimit(1)
                            Text(track.artists).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button { player.play(uri: track.uri) } label: { Image(systemName: "play.fill") }
                            .help(String(localized: "spotify.api.playNow", defaultValue: "Play now"))
                        if showsAdd {
                            Button { Task { await api.addToQueue(track) } } label: { Image(systemName: "text.badge.plus") }
                                .help(String(localized: "spotify.api.addToQueue", defaultValue: "Add to queue"))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
