//
//  AlbumDB.swift
//
//  What this app has learned about albums, kept on disk so a song from a known album starts at once, with no lookup:
//  each album's animated cover, or the fact that it has none. The first run takes over what the helper app it replaced
//  had saved.
//

import Foundation

@MainActor
final class AlbumDB {
    static let shared = AlbumDB()

    private var links: [String: String] = [:]       // "artist|album" -> animated cover address
    private var noMotion: [String: Date] = [:]       // "artist|album" -> when it was found to have none
    private var listened: [String: Date] = [:]       // "artist|album" -> when you last played it
    private var brightness: [String: Double] = [:]   // "artist|album" -> how light its cover is, 0...1
    private static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    private static let file = directory.appendingPathComponent("AlbumscapeLock/albums.json")
    private static let helperState = directory.appendingPathComponent("DroppyMotionFill/state.json")

    init() {
        if let data = try? Data(contentsOf: Self.file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            links = json["links"] as? [String: String] ?? [:]
            noMotion = (json["none"] as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
            listened = (json["listened"] as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
            brightness = json["brightness"] as? [String: Double] ?? [:]
        } else if let data = try? Data(contentsOf: Self.helperState),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let old = json["albumLinks"] as? [String: String] {
            links = old.filter { $0.value.hasPrefix("http") }
            seedListenedFromHelper(json)
            save()
            Debug.log("album database: took over \(links.count) animated albums from the helper")
        }
        if listened.isEmpty, let data = try? Data(contentsOf: Self.helperState), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            seedListenedFromHelper(json)
            save()
        }
    }

    /// The helper kept the songs and albums you played: those are what the idle shuffle is drawn from.
    private func seedListenedFromHelper(_ json: [String: Any]) {
        let now = Date()
        for album in json["recentAlbums"] as? [String] ?? [] { listened[album.lowercased()] = now }
        for entry in json["played"] as? [String] ?? [] {
            let parts = entry.components(separatedBy: "|")
            if parts.count >= 3 { listened["\(Self.mainArtist(parts[1]))|\(parts[2...].joined(separator: "|"))".lowercased()] = now }
        }
    }

    func setBrightness(_ value: Double, for track: Track) {
        brightness[Self.key(track)] = value
        save()
    }

    /// Night (10 PM to 6 AM): darker covers, slower; morning (6 AM to noon): lighter ones; otherwise no preference.
    enum Daypart { case night, morning, day
        static var now: Daypart {
            let h = Calendar.current.component(.hour, from: Date())
            return (h >= 22 || h < 6) ? .night : (h < 12 ? .morning : .day)
        }
    }

    func noteListened(_ track: Track) {
        listened[Self.key(track)] = Date()
        save()
    }

    static func key(_ track: Track) -> String { "\(mainArtist(track.artist))|\(track.album)".lowercased() }

    /// Spotify names the first artist of a song; a guest artist's name shouldn't make a different album of it.
    private static func mainArtist(_ artist: String) -> String {
        artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?
            .replacingOccurrences(of: #"\s+(feat\.?|ft\.?|with)\s+.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces) ?? artist
    }

    enum Answer { case motion(URL), none, unknown }

    func answer(for track: Track) -> Answer {
        let key = Self.key(track)
        if let link = links[key], let url = URL(string: link) { return .motion(url) }
        // the same album saved under its own artist (a song by a guest artist): a long enough name isn't a coincidence
        let name = track.album.lowercased()
        if name.count >= 8, let link = links.first(where: { $0.key.hasSuffix("|" + name) })?.value, let url = URL(string: link) { return .motion(url) }
        if let when = noMotion[key], Date().timeIntervalSince(when) < 14 * 86_400 { return .none }
        return .unknown
    }

    /// A random animated album from what's been saved, for the idle shuffle.
    func randomMotion(excluding last: URL?) -> (url: URL, album: String)? {
        // Albums you've played (matched by album name, since Apple may list one under another artist); with none yet, all.
        let heard = Set(listened.keys.map { $0.components(separatedBy: "|").dropFirst().joined(separator: "|") })
        var pool = links.filter { $0.value.hasPrefix("http") && URL(string: $0.value) != last && heard.contains($0.key.components(separatedBy: "|").dropFirst().joined(separator: "|")) }
        if pool.isEmpty { pool = links.filter { $0.value.hasPrefix("http") && URL(string: $0.value) != last } }
        // Weighted by the time of day: at night the dark covers are likelier, in the morning the light ones. A cover not
        // measured yet counts as middling.
        let part = Daypart.now
        func weight(_ key: String) -> Double {
            let b = brightness[key] ?? 0.5
            switch part {
            case .night: return 0.08 + pow(1 - b, 2.2)
            case .morning: return 0.08 + pow(b, 1.6)
            case .day: return 1
            }
        }
        let entries = Array(pool)
        let total = entries.reduce(0.0) { $0 + weight($1.key) }
        var roll = Double.random(in: 0..<max(total, 0.0001))
        var chosen = entries.randomElement()
        for entry in entries { roll -= weight(entry.key); if roll <= 0 { chosen = entry; break } }
        guard let pick = chosen, let url = URL(string: pick.value) else { return nil }
        return (url, pick.key.components(separatedBy: "|").dropFirst().joined(separator: "|"))
    }

    func remember(_ track: Track, motion: URL?) {
        let key = Self.key(track)
        if let motion { links[key] = motion.absoluteString; noMotion[key] = nil } else { noMotion[key] = Date() }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json: [String: Any] = ["links": links, "none": noMotion.mapValues { $0.timeIntervalSince1970 }, "listened": listened.mapValues { $0.timeIntervalSince1970 }, "brightness": brightness]
        if let data = try? JSONSerialization.data(withJSONObject: json) { try? data.write(to: Self.file) }
    }
}
