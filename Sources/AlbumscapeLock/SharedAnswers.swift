//
//  SharedAnswers.swift
//
//  The helper that keeps Droppy's cache full (DroppyMotionFill) has already worked out which albums have animated
//  covers, including ones Apple lists under another artist than the one Spotify names (a song by a guest artist on
//  someone else's album). When this app's own lookup finds none, ask what the helper saved.
//

import Foundation

enum SharedAnswers {
    private static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DroppyMotionFill/state.json")

    /// The animated cover's address for this song, if the helper saved one (not a still-cover video).
    static func motion(for track: Track) -> URL? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pending = json["pending"] as? [String: String] else { return nil }
        let key = "\(track.title)|\(track.artist)|\(track.album)".lowercased()
        guard let link = pending[key], link.hasPrefix("http") else { return nil }
        return URL(string: link)
    }
}
