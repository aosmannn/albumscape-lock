//
//  Lyrics.swift
//
//  Time-synced lyrics from LRCLIB (free, no key), found and read the way the Windows Albumscape does it: the closest
//  match by length within four seconds, so a live or sped-up version doesn't win.
//

import Foundation

struct LyricLine: Equatable {
    let time: TimeInterval
    let text: String
}

actor LyricsFinder {
    private var cache: [String: [LyricLine]] = [:]
    private let session = URLSession(configuration: .ephemeral)

    /// nil when the network failed (so "no lyrics" isn't remembered); [] when none exist.
    func lyrics(for track: Track) async -> [LyricLine]? {
        if let hit = cache[track.key] { return hit }
        var failed = false
        for artist in artistNames(track.artist) {
            switch await search(title: track.title, artist: artist, duration: track.duration) {
            case .some(let lines) where !lines.isEmpty:
                cache[track.key] = lines
                return lines
            case .none: failed = true
            default: break
            }
        }
        if failed { return nil }
        cache[track.key] = []
        return []
    }

    /// The artist as given, then the first of several ("A, B" or "A & B"), which is how LRCLIB often lists a song.
    private func artistNames(_ artist: String) -> [String] {
        var names = [artist]
        let first = artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?.trimmingCharacters(in: .whitespaces) ?? artist
        if first != artist, !first.isEmpty { names.append(first) }
        return names
    }

    private func search(title: String, artist: String, duration: TimeInterval) async -> [LyricLine]? {
        var parts = URLComponents(string: "https://lrclib.net/api/search")!
        parts.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Albumscape (github.com/aosmannn/albumscape-releases)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var best: String?
        var bestGap = Double.infinity
        for item in items {
            guard let synced = item["syncedLyrics"] as? String, !synced.isEmpty else { continue }
            let gap = duration > 0 ? abs((item["duration"] as? Double ?? 0) - duration) : 0
            if duration > 0, gap > 4 { continue }  // a different version (live, remix, sped up...)
            if gap < bestGap { best = synced; bestGap = gap }
        }
        return best.map(Self.parse) ?? []
    }

    /// "[01:02.50] words" lines, sorted by time.
    static func parse(_ text: String) -> [LyricLine] {
        guard let stamp = try? NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#),
              let tag = try? NSRegularExpression(pattern: #"\[[^\]]*\]"#) else { return [] }
        var lines: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let range = NSRange(raw.startIndex..., in: raw)
            let words = tag.stringByReplacingMatches(in: raw, range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
            for m in stamp.matches(in: raw, range: range) {
                guard let a = Range(m.range(at: 1), in: raw), let b = Range(m.range(at: 2), in: raw),
                      let mins = Double(raw[a]), let secs = Double(raw[b]) else { continue }
                lines.append(LyricLine(time: mins * 60 + secs, text: words))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }
}
