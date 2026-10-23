import Foundation

/// A source for music that doesn't play in Spotify or Music on this Mac: Last.fm's "now playing" for your account shows
/// what any scrobbling app is playing (a web player, Tidal, YouTube Music, or Spotify on your phone). It can't pause or
/// skip those, and it has no clock, so the position is counted from when a song is first seen.
@MainActor
final class LastFM {
    static let shared = LastFM()
    static var user: String { (UserDefaults.standard.string(forKey: "lastfmUser") ?? "").trimmingCharacters(in: .whitespaces) }
    static var key: String { (UserDefaults.standard.string(forKey: "lastfmKey") ?? "").trimmingCharacters(in: .whitespaces) }
    static var configured: Bool { UserDefaults.standard.bool(forKey: "lastfmOn") && !user.isEmpty && !key.isEmpty }
    static let bundle = "lastfm"  // Track.source for songs from here: the controls have nowhere to go

    private var seenKey = ""
    private var seenAt = Date()
    private var duration: TimeInterval = 0
    private var lastFetch = Date.distantPast
    private var cached: Track?

    /// What's playing now, or nil. Asks Last.fm at most every 6 seconds.
    func nowPlaying() async -> Track? {
        guard Self.configured else { return nil }
        if Date().timeIntervalSince(lastFetch) < 6 { return advance(cached) }
        lastFetch = Date()
        guard var parts = URLComponents(string: "https://ws.audioscrobbler.com/2.0/") else { return nil }
        parts.queryItems = [.init(name: "method", value: "user.getrecenttracks"), .init(name: "user", value: Self.user),
                            .init(name: "api_key", value: Self.key), .init(name: "format", value: "json"), .init(name: "limit", value: "1")]
        guard let url = parts.url, let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recent = json["recenttracks"] as? [String: Any] else { cached = nil; return nil }
        let list = (recent["track"] as? [[String: Any]]) ?? []
        guard let first = list.first, (first["@attr"] as? [String: Any])?["nowplaying"] as? String == "true",
              let title = first["name"] as? String else { cached = nil; return nil }
        let artist = ((first["artist"] as? [String: Any])?["#text"] as? String) ?? ""
        let album = ((first["album"] as? [String: Any])?["#text"] as? String) ?? ""
        var cover = ""
        if let images = first["image"] as? [[String: Any]], let big = images.last?["#text"] as? String { cover = big }
        let track = Track(title: title, artist: artist, album: album, isPlaying: true, position: 0, duration: 0, artworkURL: cover, source: Self.bundle)
        if track.key != seenKey {
            seenKey = track.key
            seenAt = Date().addingTimeInterval(-3)  // it was seen a few seconds after it began
            duration = await length(of: title, by: artist)
        }
        cached = track
        return advance(track)
    }

    private func advance(_ track: Track?) -> Track? {
        guard var t = track else { return nil }
        t.position = min(Date().timeIntervalSince(seenAt), duration > 0 ? duration : .infinity)
        t.duration = duration
        return t
    }

    private func length(of title: String, by artist: String) async -> TimeInterval {
        guard var parts = URLComponents(string: "https://ws.audioscrobbler.com/2.0/") else { return 0 }
        parts.queryItems = [.init(name: "method", value: "track.getInfo"), .init(name: "track", value: title), .init(name: "artist", value: artist),
                            .init(name: "api_key", value: Self.key), .init(name: "format", value: "json")]
        guard let url = parts.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json["track"] as? [String: Any], let ms = (info["duration"] as? String).flatMap(Double.init) else { return 0 }
        return ms / 1000
    }
}
