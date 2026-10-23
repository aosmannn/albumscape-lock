//
//  YouTubeVideo.swift
//  Albumscape
//
//  Finds a song's official music video through Albumscape's lookup service,
//  ported from lockscreen_music.py (shared_music_video, free_video,
//  verify_candidate, _yt_pick). Candidates are always checked against the
//  video's real title and channel before one is shown.
//

import Foundation

struct YouTubeVideo: Equatable {
    var id: String
    var isVisualizer: Bool
    var offset: TimeInterval  // seconds into the video where the song starts
}

actor YouTubeFinder {
    private let service = "https://albumscape.vercel.app/api"
    private let sharedList = URL(string: "https://raw.githubusercontent.com/aosmannn/albumscape-releases/main/videos.json")!
    private let blockedList = URL(string: "https://raw.githubusercontent.com/aosmannn/albumscape-releases/main/blocked.json")!
    private let session = URLSession(configuration: .ephemeral)

    private var shared: [String: [String: Any]]?
    private var sharedAt = Date.distantPast
    private var blocked: Set<String> = []
    private var blockedAt = Date.distantPast
    private var cache: [String: YouTubeVideo?] = [:]
    /// Every song's answer is kept on disk, so a song heard before gets its video at once, even after a restart.
    private static let cacheFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AlbumscapeLock/videos.json")
    private var loaded = false

    func video(for track: Track) async -> YouTubeVideo? {
        loadCache()
        if let hit = cache[track.key] { return hit }
        guard let found = await find(track) else { return nil }  // nothing is remembered when a service was down
        cache.updateValue(found.value, forKey: track.key)  // a nil value means "checked: none", so not plain assignment
        saveCache()
        return found.value
    }

    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.cacheFile), let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }
        for (key, v) in json {
            if let id = v["id"] as? String { cache[key] = YouTubeVideo(id: id, isVisualizer: v["visualizer"] as? Bool ?? false, offset: v["offset"] as? Double ?? 0) }
            else { cache.updateValue(nil, forKey: key) }
        }
    }

    private func saveCache() {
        var json: [String: [String: Any]] = [:]
        for (key, v) in cache { json[key] = v.map { ["id": $0.id, "visualizer": $0.isVisualizer, "offset": $0.offset] } ?? [:] }
        try? FileManager.default.createDirectory(at: Self.cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: json) { try? data.write(to: Self.cacheFile) }
    }

    /// `.some(nil)` means "checked: there is no video"; `nil` means "couldn't tell, try again".
    private func find(_ track: Track) async -> Box? {
        guard !words(track.artist).isEmpty else { return Box(nil) }
        await refreshBlocked()

        if let entry = await sharedEntry(track) {
            if let id = entry["id"] as? String, !blocked.contains(id) {
                return Box(YouTubeVideo(id: id, isVisualizer: false, offset: entry["offset"] as? Double ?? 0))
            }
            return Box(nil)  // the list says "no music video" for this song
        }

        // Both sources at once, then every candidate checked at once; the first in order that is the real video wins.
        async let geniusIDs = ids("genius", track, limit: 4)
        async let searchIDs = ids("ytsearch", track, limit: 12)
        let pools = await [geniusIDs, searchIDs]
        guard pools.contains(where: { $0 != nil }) else { return nil }
        var candidates: [String] = []
        for id in pools.compactMap({ $0 }).joined() where !candidates.contains(id) && !blocked.contains(id) { candidates.append(id) }
        if candidates.isEmpty { return Box(nil) }
        return await withTaskGroup(of: (Int, Kind).self) { group -> Box in
            for (i, id) in candidates.enumerated() { group.addTask { (i, await self.verify(track, id)) } }
            var results = [Kind?](repeating: nil, count: candidates.count)
            for await (i, kind) in group {
                results[i] = kind
                // decided as soon as every earlier candidate is known: the first real video, in order
                for (j, r) in results.enumerated() {
                    guard let r else { break }
                    if r == .video { group.cancelAll(); return Box(YouTubeVideo(id: candidates[j], isVisualizer: false, offset: 0)) }
                }
            }
            if let j = results.firstIndex(where: { $0 == .visualizer }) { return Box(YouTubeVideo(id: candidates[j], isVisualizer: true, offset: 0)) }
            return Box(nil)
        }
    }

    private struct Box { let value: YouTubeVideo?; init(_ v: YouTubeVideo?) { value = v } }

    // MARK: Sources

    private func get(_ url: URL, timeout: TimeInterval = 20) async -> Data? {
        guard let (data, response) = try? await session.data(for: URLRequest(url: url, timeoutInterval: timeout)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private func sharedEntry(_ track: Track) async -> [String: Any]? {
        if shared == nil || Date().timeIntervalSince(sharedAt) > 12 * 3600 {
            sharedAt = Date()
            if let data = await get(sharedList, timeout: 15),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let videos = root["videos"] as? [String: [String: Any]] { shared = videos }
        }
        return shared?[Self.listKey(track.artist, track.title)]
    }

    private func refreshBlocked() async {
        guard Date().timeIntervalSince(blockedAt) > 6 * 3600 else { return }
        blockedAt = Date()
        if let data = await get(blockedList, timeout: 6),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = root["ids"] as? [String] { blocked = Set(list) }
    }

    private func ids(_ endpoint: String, _ track: Track, limit: Int) async -> [String]? {
        var c = URLComponents(string: "\(service)/\(endpoint)")!
        c.queryItems = [.init(name: "artist", value: track.artist), .init(name: "title", value: track.title)]
        guard let data = await get(c.url!),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if endpoint == "genius", root["found"] as? Bool != true { return [] }
        return Array((root["ids"] as? [String] ?? []).prefix(limit))
    }

    // MARK: Verification

    private enum Kind { case video, visualizer, none }

    private func verify(_ track: Track, _ id: String) async -> Kind {
        var c = URLComponents(string: "https://www.youtube.com/oembed")!
        c.queryItems = [.init(name: "url", value: "https://www.youtube.com/watch?v=\(id)"), .init(name: "format", value: "json")]
        guard let data = await get(c.url!, timeout: 10),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = info["title"] as? String, let channel = info["author_name"] as? String else { return .none }
        let kind: Kind = pick(track, title: title, channel: channel, visualizer: false) ? .video
            : pick(track, title: title, channel: channel, visualizer: true) ? .visualizer : .none
        guard kind != .none else { return .none }

        // Right song, but it must be the artist's own verified channel.
        var v = URLComponents(string: "\(service)/ytverify")!
        v.queryItems = [.init(name: "id", value: id)]
        guard let vdata = await get(v.url!),
              let check = try? JSONSerialization.jsonObject(with: vdata) as? [String: Any] else { return .none }
        let views = (check["views"] as? Int) ?? Int(check["views"] as? Double ?? 0)
        guard check["artist"] as? Bool == true || (Self.allowOtherChannels && views >= Self.minViews) else { return .none }
        return kind
    }

    private static let notTheVideo: Set<String> = [
        "lyric", "lyrics", "audio", "live", "reaction", "cover", "remix", "slowed", "reverb", "sped", "instrumental",
        "karaoke", "8d", "nightcore", "teaser", "trailer", "snippet", "behind", "dance", "tutorial", "review", "edit",
        "alternate", "alt", "demo", "acoustic", "unreleased", "leaked", "leak", "mashup", "extended", "stripped",
        "interlude", "preview"]
    private static let noise: Set<String> = [
        "official", "music", "video", "visualizer", "visualiser", "visualizr", "hd", "4k", "audio", "explicit", "clean",
        "lyric", "lyrics", "mv", "m", "v", "uncensored", "remastered"]
    /// Albumscape's "Videos from other channels": a label's or director's upload that a real audience has watched
    /// counts too (for example Lyrical Lemonade's official video). A throwaway copy has a few views, not thousands.
    private static let allowOtherChannels = true
    private static let minViews = 100_000  // Albumscape uses 20,000; that let an unofficial upload through
    private static let saysVideo: Set<String> = ["official", "video", "visual", "dir", "directed", "mv", "film", "clip"]
    private static let visualizerWords: Set<String> = ["visualizer", "visualiser", "visualizr"]

    /// `_yt_pick` for one upload: the right song, an official upload by the artist, no lyric/audio/alternate/Topic uploads.
    private func pick(_ track: Track, title raw: String, channel channelRaw: String, visualizer wantVisualizer: Bool) -> Bool {
        let mainArtist = track.artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?
            .replacingOccurrences(of: #"\s+(feat\.?|ft\.?|with|x)\s+.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces) ?? track.artist
        let wantArtist = words(mainArtist)
        let wantAll = words(clean(track.title))
        let want = wantAll.subtracting(wantArtist).isEmpty ? wantAll : wantAll.subtracting(wantArtist)
        let wantFullRaw = words(track.title).subtracting(wantArtist)
        let wantFull = wantFullRaw.isEmpty ? wantAll : wantFullRaw

        let titleWords = words(raw)
        guard !titleWords.isDisjoint(with: Self.visualizerWords) == wantVisualizer else { return false }
        if channelRaw.range(of: #"-\s*topic\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        let channel = words(channelRaw.replacingOccurrences(of: "VEVO", with: " vevo").replacingOccurrences(of: "Vevo", with: " vevo"))
        guard Self.notTheVideo.intersection(titleWords).subtracting(wantAll).subtracting(wantFull).isEmpty else { return false }

        let core = songWords(raw, artist: wantArtist, keepParens: false)
        guard core == want || core == wantFull || [want, wantFull].contains(songWords(raw, artist: wantArtist, keepParens: true)) else { return false }

        let squash = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let byArtist = wantArtist.isSubset(of: channel)
            || (!wantArtist.isDisjoint(with: channel) && channel.contains("vevo"))
            || (squash(mainArtist).count >= 4 && squash(channelRaw).contains(squash(mainArtist)))
        if !byArtist {
            // Someone else's upload must read "Artist - Song", and a visualizer must say "Official".
            let low = raw.lowercased()
            guard let a = low.range(of: track.artist.lowercased()), let b = low.range(of: clean(track.title).lowercased()),
                  a.lowerBound <= b.lowerBound else { return false }
            if wantVisualizer && !titleWords.contains("official") { return false }
        }
        let official = titleWords.contains("official") && (wantVisualizer || titleWords.contains("video"))
        var score = (byArtist ? 3 : 0) + (official ? 2 : 0) + (channel.contains("vevo") ? 1 : 0)
        if Self.allowOtherChannels, !wantVisualizer, !byArtist, !titleWords.isDisjoint(with: Self.saysVideo) { score = max(score, 1) }
        return score >= (Self.allowOtherChannels ? 1 : 2)
    }

    /// "Artist - Song (Official Video) ft. X" -> {song}
    private func songWords(_ raw: String, artist: Set<String>, keepParens: Bool) -> Set<String> {
        var t = raw
        if !keepParens { t = t.replacingOccurrences(of: #"\(.*?\)|\[.*?\]"#, with: " ", options: .regularExpression) }
        t = t.components(separatedBy: " ft").first ?? t
        t = t.replacingOccurrences(of: #"\b(feat|featuring)\b\.?.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let parts = t.components(separatedBy: " - ")
        if parts.count >= 2 {
            let left = words(parts[0]), right = words(parts[1])
            t = (!left.isDisjoint(with: artist) || right.isDisjoint(with: artist)) ? parts[1] : parts[0]
        }
        return words(t).subtracting(artist).subtracting(Self.noise)
    }

    private func words(_ s: String) -> Set<String> {
        Set(s.folding(options: .diacriticInsensitive, locale: nil).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    private func clean(_ title: String) -> String {
        var t = title
        for p in [#"\s*[\(\[][^\)\]]*[\)\]]"#, #"\s+-\s+.*$"#] { t = t.replacingOccurrences(of: p, with: "", options: .regularExpression) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// The shared list's key: main artist + song title, lowercase words only.
    static func listKey(_ artist: String, _ title: String) -> String {
        func norm(_ s: String) -> String {
            let plain = s.folding(options: .diacriticInsensitive, locale: nil).lowercased()
                .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
            return plain.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        let main = artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?
            .replacingOccurrences(of: #"\s+(feat\.?|ft\.?|with|x)\s+.*$"#, with: "", options: [.regularExpression, .caseInsensitive]) ?? artist
        let song = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+-\s+.*$"#, with: "", options: .regularExpression)
        return "\(norm(main))|\(norm(song))"
    }
}
