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
    private static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    private static let file = directory.appendingPathComponent("AlbumscapeLock/albums.json")
    private static let helperState = directory.appendingPathComponent("DroppyMotionFill/state.json")

    init() {
        if let data = try? Data(contentsOf: Self.file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            links = json["links"] as? [String: String] ?? [:]
            noMotion = (json["none"] as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
        } else if let data = try? Data(contentsOf: Self.helperState),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let old = json["albumLinks"] as? [String: String] {
            links = old.filter { $0.value.hasPrefix("http") }
            save()
            Debug.log("album database: took over \(links.count) animated albums from the helper")
        }
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

    func remember(_ track: Track, motion: URL?) {
        let key = Self.key(track)
        if let motion { links[key] = motion.absoluteString; noMotion[key] = nil } else { noMotion[key] = Date() }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json: [String: Any] = ["links": links, "none": noMotion.mapValues { $0.timeIntervalSince1970 }]
        if let data = try? JSONSerialization.data(withJSONObject: json) { try? data.write(to: Self.file) }
    }
}
