//
//  Spotify.swift
//
//  Connects your Spotify account the way Droppy does (Authorization Code with PKCE: no secret, your password never
//  touches this app) so the player knows which songs you've liked and the heart works. Needs a free Spotify app of
//  your own for its client ID: https://developer.spotify.com/dashboard, with the redirect address below.
//

import AppKit
import CryptoKit
import Network
import Security

@MainActor
final class SpotifyAccount: ObservableObject {
    static let shared = SpotifyAccount()
    static let redirect = "http://127.0.0.1:3000/api/spotify/callback"  // already listed on the Spotify app; used only while connecting
    private static let service = "com.adam.albumscape-lock.spotify"

    @Published private(set) var connected = false
    var clientID: String { (UserDefaults.standard.string(forKey: "spotifyClientID") ?? "").trimmingCharacters(in: .whitespaces) }

    /// Spotify said wait (429 + Retry-After): until then no request is sent, so the allowance isn't spent again.
    private(set) var blockedUntil = Date.distantPast
    var blockedMessage: String? {
        guard Date() < blockedUntil else { return nil }
        let f = DateFormatter(); f.timeStyle = .short
        return "Spotify is limiting this app until \(f.string(from: blockedUntil))"
    }
    private var accessToken: String?
    private var expires = Date.distantPast
    private var verifier = ""
    private var state = ""
    private var listener: NWListener?

    init() {
        connected = Self.loadRefreshToken() != nil
        loadLikedFile()
        if connected { Task { await self.syncLiked() } }
    }

    /// Asks Spotify who is signed in and what plan it sees, so a refusal can be told from a wrong account.
    func probe() async {
        guard let token = await token(), let r = await call("GET", "https://api.spotify.com/v1/me", token: token) else { return }
        let json = (try? JSONSerialization.jsonObject(with: r.data) as? [String: Any]) ?? [:]
        Debug.log("spotify: /me -> \(r.status) id=\(json["id"] ?? "?") product=\(json["product"] ?? "hidden") country=\(json["country"] ?? "?")")
    }

    // MARK: Connect

    func connect() {
        guard !clientID.isEmpty else { Debug.log("spotify: no client ID (set it from the menu bar icon)"); return }
        verifier = Self.random(64)
        state = Self.random(16)
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        listener?.cancel()
        do {
            let port = NWEndpoint.Port(rawValue: 3000)!
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let ok = request.contains("code=")
                    let page = "<html><body style='font-family:-apple-system;text-align:center;padding-top:20vh'><h2>\(ok ? "Spotify connected" : "Spotify did not connect")</h2><p>You can close this tab.</p></body></html>"
                    let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    MainActor.assumeIsolated { self?.handleCallback(request) }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            Debug.log("spotify: couldn't listen on port 3000 (is a dev server running?): \(error)")
            return
        }
        var parts = URLComponents(string: "https://accounts.spotify.com/authorize")!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirect), URLQueryItem(name: "scope", value: "user-library-read user-library-modify"),
            URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state)]
        if let url = parts.url { NSWorkspace.shared.open(url) }
        Debug.log("spotify: waiting for you to approve in the browser")
    }

    private func handleCallback(_ request: String) {
        listener?.cancel()
        listener = nil
        // "GET /callback?code=...&state=... HTTP/1.1"
        guard let line = request.components(separatedBy: "\r\n").first, let target = line.split(separator: " ").dropFirst().first,
              let items = URLComponents(string: "http://x\(target)")?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value,
              items.first(where: { $0.name == "state" })?.value == state else { Debug.log("spotify: the approval didn't come back"); return }
        Task { await self.exchange(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect, "code_verifier": verifier]) }
    }

    func disconnect() {
        Self.deleteRefreshToken()
        accessToken = nil
        connected = false
        Debug.log("spotify: disconnected")
    }

    // MARK: Tokens

    private func exchange(_ form: [String: String]) async {
        var body = form
        body["client_id"] = clientID
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.map { "\($0.key)=\(Self.encode($0.value))" }.joined(separator: "&").data(using: .utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { Debug.log("spotify: token request failed"); return }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let token = json["access_token"] as? String else {
            Debug.log("spotify: token refused: \(json["error_description"] ?? json["error"] ?? "?")")
            if (json["error"] as? String) == "invalid_grant" { disconnect() }
            return
        }
        accessToken = token
        expires = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
        if let refresh = json["refresh_token"] as? String { Self.saveRefreshToken(refresh) }
        let first = !connected
        if first { Debug.log("spotify: connected") }
        connected = true
        if first { Task { await self.syncLiked(force: true) } }
    }

    private func token() async -> String? {
        if let accessToken, Date() < expires { return accessToken }
        guard let refresh = Self.loadRefreshToken() else { return nil }
        await exchange(["grant_type": "refresh_token", "refresh_token": refresh])
        return accessToken
    }

    // MARK: Liked songs

    /// One call to Spotify; logs what it said when it wasn't happy, so a refusal can be read instead of guessed.
    private func call(_ method: String, _ url: String, token: String) async -> (status: Int, data: Data)? {
        guard let u = URL(string: url), Date() >= blockedUntil else { return nil }
        var request = URLRequest(url: u)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request), let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        if !(200..<300).contains(status) {
            let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            if status == 429, let retry { blockedUntil = Date().addingTimeInterval(retry) }
            let wait = retry.map { " retry-after=\(Int($0))s" } ?? ""
            Debug.log("spotify: \(method) \(u.path) -> \(status)\(wait) \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
        return (status, data)
    }

    func isLiked(_ trackID: String) async -> Bool? {
        guard let token = await token() else { return nil }
        if let r = await call("GET", "https://api.spotify.com/v1/me/tracks/contains?ids=\(trackID)", token: token), r.status == 200,
           let list = try? JSONSerialization.jsonObject(with: r.data) as? [Bool] { return list.first }
        // Spotify's newer library address
        if let r = await call("GET", "https://api.spotify.com/v1/me/library/contains?uris=spotify:track:\(trackID)", token: token), r.status == 200,
           let list = try? JSONSerialization.jsonObject(with: r.data) as? [Bool] { return list.first }
        return nil
    }

    @discardableResult
    func setLiked(_ trackID: String, _ liked: Bool) async -> Bool {
        guard let token = await token() else { return false }
        let method = liked ? "PUT" : "DELETE"
        var ok = (await call(method, "https://api.spotify.com/v1/me/tracks?ids=\(trackID)", token: token))?.status == 200
        if !ok { ok = (await call(method, "https://api.spotify.com/v1/me/library?uris=spotify:track:\(trackID)", token: token)).map { (200..<300).contains($0.status) } ?? false }
        Debug.log("spotify: \(liked ? "liked" : "unliked") \(trackID): \(ok ? "ok" : "failed")")
        if ok { if liked { self.liked.insert(trackID) } else { self.liked.remove(trackID) }; likedCount = self.liked.count; saveLikedFile() }
        return ok
    }

    // MARK: Your liked songs, read once and kept

    /// The ids of the songs in your Liked Songs, read in pages of 50 and remembered, so a song change costs no request at
    /// all. (Asking Spotify about every song, again and again, is what used up the allowance before.) The heart changes
    /// this list at once and tells Spotify with a single request.
    @Published private(set) var likedCount = 0
    private var liked: Set<String> = []
    private var syncedAt = Date.distantPast
    private var syncing = false
    private static let likedFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AlbumscapeLock/liked-songs.json")

    var hasLikedList: Bool { syncedAt > .distantPast }
    func isLikedCached(_ id: String) -> Bool { liked.contains(id) }

    private func loadLikedFile() {
        guard let data = try? Data(contentsOf: Self.likedFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = json["ids"] as? [String], let at = json["syncedAt"] as? Double else { return }
        liked = Set(ids)
        likedCount = liked.count
        syncedAt = Date(timeIntervalSince1970: at)
    }

    private func saveLikedFile() {
        try? FileManager.default.createDirectory(at: Self.likedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json: [String: Any] = ["ids": Array(liked), "syncedAt": syncedAt.timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: json) { try? data.write(to: Self.likedFile) }
    }

    /// Reads Liked Songs if it hasn't been read in the last six hours (or `force`). Stops quietly if Spotify says wait.
    func syncLiked(force: Bool = false) async {
        guard connected, !syncing, force || Date().timeIntervalSince(syncedAt) > 6 * 3600, Date() >= blockedUntil else { return }
        syncing = true
        defer { syncing = false }
        var ids: Set<String> = []
        var offset = 0
        while offset < 5000 {
            guard let token = await token(), let r = await call("GET", "https://api.spotify.com/v1/me/tracks?limit=50&offset=\(offset)&fields=items(track(id)),next", token: token),
                  r.status == 200, let json = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else { Debug.log("spotify: reading liked songs stopped at \(offset)"); return }
            for item in items { if let id = (item["track"] as? [String: Any])?["id"] as? String { ids.insert(id) } }
            if json["next"] is NSNull || json["next"] == nil || items.isEmpty { break }
            offset += 50
            try? await Task.sleep(for: .milliseconds(200))
        }
        liked = ids
        likedCount = ids.count
        syncedAt = Date()
        saveLikedFile()
        Debug.log("spotify: read \(ids.count) liked songs")
    }

    // MARK: Helpers

    private static func random(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return String(base64url(Data(bytes)).prefix(n))
    }
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? s }

    private static func query() -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "refresh"] }
    private static func saveRefreshToken(_ token: String) {
        deleteRefreshToken()
        var item = query()
        item[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
    private static func loadRefreshToken() -> String? {
        var q = query()
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func deleteRefreshToken() { SecItemDelete(query() as CFDictionary) }
}
