//
//  AlbumLookup.swift
//  Albumscape
//
//  The Albumscape lookup, ported from lockscreen_music.py: iTunes Search for
//  the album, the public album page for the motion art, iTunes music videos.
//

import Foundation
import SwiftUI

/// Lets the song you're playing jump the queue: Apple's search allows only about 20 requests a minute, and the
/// background passes (whole albums, history) must not use them all.
enum LookupLane { @TaskLocal static var foreground = false }

struct AlbumArt: Equatable {
    var album: String
    /// False when a request failed along the way (Apple refusing, no network): then "no motion art" means "don't know".
    var complete = true
    var coverURL: URL?
    var motionURL: URL?      // HLS master playlist, if the album has motion art
    var videoURL: URL?       // Apple's music video preview, if the song has one
    var accent: Color?

    static func == (a: AlbumArt, b: AlbumArt) -> Bool {
        a.album == b.album && a.coverURL == b.coverURL && a.motionURL == b.motionURL && a.videoURL == b.videoURL
    }
}

actor AlbumLookup {
    private var cache: [String: AlbumArt] = [:]
    private var blockedUntil = Date.distantPast        // Apple said 403/429: leave it alone for a while
    private var failureCount = 0
    private var nextForeground = Date.distantPast       // pacing: the next time each lane may call iTunes
    private var nextBackground = Date.distantPast

    func isBlocked() -> Bool { Date() < blockedUntil }

    // MARK: Apple Music's website (not the iTunes API)

    /// What an Apple Music album page tells us: the album, its artist, its cover, its animation and its songs.
    struct WebAlbum { let id: String; let name: String; let artist: String; let cover: URL?; let motion: URL?; let tracks: [String] }
    private var webCache: [String: WebAlbum] = [:]
    private var nextWebForeground = Date.distantPast
    private var nextWebBackground = Date.distantPast

    private func htmlUnescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }

    /// A page from music.apple.com. Spaced out a little too, so the site is never hammered either.
    private func webPage(_ url: URL) async -> String? {
        let foreground = LookupLane.foreground
        let gap: TimeInterval = foreground ? 0.8 : 2.5
        let slot = max(Date(), foreground ? nextWebForeground : nextWebBackground)
        if foreground { nextWebForeground = slot.addingTimeInterval(gap) } else { nextWebBackground = slot.addingTimeInterval(gap) }
        let wait = slot.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
            failureCount += 1
            return nil
        }
        return html
    }

    private func metaContent(_ property: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<meta property=\"\(property)\" content=\"([^\"]*)\""),
              let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html) else { return nil }
        return htmlUnescape(String(html[r]))
    }

    private func webAlbum(id: String) async -> WebAlbum? {
        if let hit = webCache[id] { return hit }
        guard let page = URL(string: "https://music.apple.com/\(storefront)/album/\(id)"), let html = await webPage(page) else { return nil }
        // "Whole Lotta Red by Playboi Carti on Apple Music"
        guard var title = metaContent("og:title", in: html), title.hasSuffix(" on Apple Music") else { return nil }
        title.removeLast(" on Apple Music".count)
        guard let by = title.range(of: " by ", options: .backwards) else { return nil }
        let name = String(title[..<by.lowerBound]), artist = String(title[by.upperBound...])
        var cover: URL?
        if let image = metaContent("og:image", in: html) {
            cover = URL(string: image.replacingOccurrences(of: #"/\d+x\d+[a-z]*(-\d+)?\.(jpg|png)$"#, with: "/2000x2000bb.jpg", options: .regularExpression))
        }
        var motion: URL?
        for kind in ["motionDetailSquare", "motionSquareVideo1x1", "motionDetailTall", "motionTallVideo3x4"] {
            if let link = firstMatch("\"\(kind)\":\\{.*?\"video\":\"(https:[^\"]+\\.m3u8)\"", in: html) { motion = URL(string: link); break }
        }
        var tracks: [String] = [], seen = Set<String>()
        if let regex = try? NSRegularExpression(pattern: "\"@type\":\"MusicRecording\",\"name\":\"((?:[^\"\\\\]|\\\\.)*)\"") {
            for m in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let r = Range(m.range(at: 1), in: html) else { continue }
                let song = htmlUnescape(String(html[r]).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\/", with: "/"))
                if seen.insert(song).inserted { tracks.append(song) }
            }
        }
        let album = WebAlbum(id: id, name: name, artist: artist, cover: cover, motion: motion, tracks: tracks)
        webCache[id] = album
        return album
    }

    /// Albums with exactly this name by this artist, found through Apple Music's website search: the way to look an album
    /// up while the iTunes API is refusing requests, or when it simply doesn't have it.
    func webAlbums(artist: String, album: String) async -> [WebAlbum] {
        let main = mainArtist(artist), wantFull = words(album), wantClean = words(clean(album))
        guard !main.isEmpty, !wantFull.isEmpty, var comps = URLComponents(string: "https://music.apple.com/\(storefront)/search") else { return [] }
        comps.queryItems = [URLQueryItem(name: "term", value: "\(main) \(clean(album))")]
        guard let url = comps.url, let html = await webPage(url),
              let regex = try? NSRegularExpression(pattern: "/\(storefront)/album/[a-z0-9%\\-]*/(\\d+)") else { return [] }
        var ids: [String] = []
        for m in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            if let r = Range(m.range(at: 1), in: html), !ids.contains(String(html[r])) { ids.append(String(html[r])) }
        }
        var found: [WebAlbum] = []
        for id in ids.prefix(8) {
            guard let candidate = await webAlbum(id: id) else { continue }
            let nameWords = words(candidate.name)
            let sameName = nameWords == wantFull || (words(clean(candidate.name)) == wantClean && !wantClean.isEmpty)
            if sameName, words(main).isSubset(of: words(candidate.artist)) { found.append(candidate) }
        }
        // an exact-name edition first (the deluxe and the plain album are different albums)
        return found.sorted { (words($0.name) == wantFull ? 0 : 1) < (words($1.name) == wantFull ? 0 : 1) }
    }

    /// The songs on an album, as Apple Music's website lists them (features written the way Spotify writes them).
    func webTracks(artist: String, album: String) async -> [String] {
        await webAlbums(artist: artist, album: album).first(where: { !$0.tracks.isEmpty })?.tracks ?? []
    }
    private let session = URLSession(configuration: .ephemeral)
    private let storefront = "us"
    private let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    /// Motion art for the album as named exactly (`strict`) or with the bracketed part dropped.
    func motion(for track: Track, strict: Bool) async -> URL? {
        for edition in (await albumsByName(track, strict: strict)).prefix(5) {
            if let url = await motionURL(albumID: edition.id).url { return url }
        }
        return nil
    }

    /// Apple's own preview clip of the song's music video (about 30 seconds, a plain link on Apple's servers), if iTunes
    /// has a music video for exactly this artist and title.
    func musicVideoPreview(for track: Track) async -> URL? { await musicVideoURL(track) }

    /// "Juice WRLD, Marshmello & The Kid LAROI" -> "Juice WRLD"
    nonisolated func mainArtist(_ artist: String) -> String {
        artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?
            .replacingOccurrences(of: #"\s+(feat\.?|ft\.?|with)\s+.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces) ?? artist
    }

    /// Every album an artist has, with its editions (explicit first) grouped together: the whole catalogue in one go.
    func albumGroups(ofArtist artist: String) async -> [[Album]] {
        let main = mainArtist(artist)
        guard !main.isEmpty else { return [] }
        let found = await search(term: main, entity: "musicArtist")
        guard let artistID = found.first(where: { words($0["artistName"] as? String ?? "") == words(main) })?["artistId"] as? Int else { return [] }
        var a = URLComponents(string: "https://itunes.apple.com/lookup")!
        a.queryItems = [.init(name: "id", value: "\(artistID)"), .init(name: "entity", value: "album"),
                        .init(name: "limit", value: "200"), .init(name: "country", value: storefront)]
        let results = ((await json(a.url!))?["results"] as? [[String: Any]] ?? []).filter { $0["collectionId"] != nil }
        var groups: [Set<String>: [[String: Any]]] = [:]
        for album in results { groups[words(album["collectionName"] as? String ?? ""), default: []].append(album) }
        return groups.values.map { editions in
            editions.sorted { ($0["collectionExplicitness"] as? String == "explicit") && ($1["collectionExplicitness"] as? String != "explicit") }
                .compactMap { e -> Album? in
                    guard let id = e["collectionId"] as? Int else { return nil }
                    return Album(id: "\(id)", name: e["collectionName"] as? String ?? "", cover: nil)
                }
        }.filter { !$0.isEmpty }
    }

    /// The first edition of an album that has motion art.
    func motion(forEditions editions: [Album]) async -> URL? {
        for page in await editionPages(Array(editions.prefix(5))) { if let url = page.url { return url } }
        return nil
    }

    /// The album page of each edition, fetched together, returned in the editions' order.
    private func editionPages(_ editions: [Album]) async -> [(url: URL?, accent: Color?)] {
        await withTaskGroup(of: (Int, URL?, Color?).self) { group in
            for (i, edition) in editions.enumerated() {
                group.addTask { let page = await self.motionURL(albumID: edition.id); return (i, page.url, page.accent) }
            }
            var found = [(url: URL?, accent: Color?)](repeating: (nil, nil), count: editions.count)
            for await (i, url, accent) in group { found[i] = (url, accent) }
            return found
        }
    }

    /// Every song on an album as Apple lists it.
    func tracks(ofAlbum id: String) async -> [(title: String, artist: String)] {
        var l = URLComponents(string: "https://itunes.apple.com/lookup")!
        l.queryItems = [.init(name: "id", value: id), .init(name: "entity", value: "song"), .init(name: "country", value: storefront)]
        return ((await json(l.url!))?["results"] as? [[String: Any]] ?? []).compactMap {
            guard $0["wrapperType"] as? String == "track", let t = $0["trackName"] as? String, let a = $0["artistName"] as? String else { return nil }
            return (t, a)
        }
    }

    func art(for track: Track) async -> AlbumArt? {
        if let hit = cache[track.key] { return hit }
        let failuresBefore = failureCount
        let albums = await findAlbums(track)
        guard let album = albums.first else {
            return failureCount == failuresBefore ? nil : AlbumArt(album: track.album, complete: false)
        }
        var art = AlbumArt(album: album.name, coverURL: album.cover)
        // Apple lists the clean and explicit editions as separate albums and only one carries the motion art: try each.
        // All the editions' pages at once, not one after the other; the first edition (in order) with motion art wins.
        let pages = await editionPages(Array(albums.prefix(5)))
        for page in pages {
            art.accent = art.accent ?? page.accent
            if let url = page.url { art.motionURL = url; break }
        }
        Debug.log("motion: tried \(min(albums.count, 5)) edition(s), found=\(art.motionURL != nil)")
        art.complete = failureCount == failuresBefore
        if art.complete { cache[track.key] = art }  // a half answer would hide the animation for good
        return art
    }

    // MARK: iTunes

    struct Album { let id: String; let name: String; let cover: URL? }

    private func json(_ url: URL, userAgent: String? = nil) async -> [String: Any]? {
        if Date() < blockedUntil { failureCount += 1; return nil }
        if url.host == "itunes.apple.com" {
            // Reserve a slot, then wait for it: simultaneous callers get spaced out instead of firing together.
            let foreground = LookupLane.foreground
            let gap: TimeInterval = foreground ? 1.5 : 6
            let slot = max(Date(), (foreground ? nextForeground : nextBackground))
            if foreground { nextForeground = slot.addingTimeInterval(gap) } else { nextBackground = slot.addingTimeInterval(gap) }
            let wait = slot.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if Date() < blockedUntil { failureCount += 1; return nil }
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 {
                Debug.log("http \(code) \(url.host ?? "") \(String(data: data.prefix(120), encoding: .utf8) ?? "")")
                failureCount += 1
                if code == 403 || code == 429 || code == 503 {
                    blockedUntil = Date().addingTimeInterval(15 * 60)
                    Debug.log("Apple is refusing requests: backing off for 15 minutes")
                }
                return nil
            }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            Debug.log("request failed \(url.host ?? ""): \(error)")
            failureCount += 1
            return nil
        }
    }

    private func search(term: String, entity: String) async -> [[String: Any]] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: term), .init(name: "entity", value: entity),
                        .init(name: "limit", value: "25"), .init(name: "country", value: storefront)]
        return (await json(c.url!))?["results"] as? [[String: Any]] ?? []
    }

    /// "Song (feat. X) - Remastered" -> "Song"
    private func clean(_ title: String) -> String {
        var t = title
        for pattern in [#"\s*[\(\[][^\)\]]*[\)\]]"#, #"\s+-\s+.*$"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    nonisolated func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    private func score(_ track: Track, _ r: [String: Any]) -> Int {
        var s = 0
        if words(r["artistName"] as? String ?? "") == words(track.artist) { s += 4 }
        else if !words(r["artistName"] as? String ?? "").isDisjoint(with: words(track.artist)) { s += 2 }
        if words(clean(r["trackName"] as? String ?? "")) == words(clean(track.title)) { s += 4 }
        if !words(r["collectionName"] as? String ?? "").isDisjoint(with: words(track.album)) { s += 2 }
        if r["trackExplicitness"] as? String == "explicit" { s += 1 }  // the edition apps play, and the one with motion art
        return s
    }

    /// The album the player reports, found by name and confirmed to contain the song, with every edition of it.
    /// Song search alone buries the original under remixes and remakes, so this goes first whenever the player gives
    /// an album. The public search only returns clean editions, so the explicit one (the one with the motion art)
    /// comes from the artist's own album list.
    /// Apple's album search often buries (or leaves out) the real album under remakes and compilations. The artist's own
    /// album list doesn't: find the artist by name, then read their albums, clean and explicit editions together.
    private func albumsViaArtist(_ track: Track, normalise: (String) -> Set<String>, wantAlbum: Set<String>) async -> [Album] {
        let main = track.artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?
            .replacingOccurrences(of: #"\s+(feat\.?|ft\.?|with)\s+.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces) ?? track.artist
        guard !main.isEmpty else { return [] }
        let found = await search(term: main, entity: "musicArtist")
        let artistIDs = found.filter { words($0["artistName"] as? String ?? "") == words(main) }
            .compactMap { $0["artistId"] as? Int }.prefix(2)
        var editions: [[String: Any]] = []
        for artistID in artistIDs {
            var a = URLComponents(string: "https://itunes.apple.com/lookup")!
            a.queryItems = [.init(name: "id", value: "\(artistID)"), .init(name: "entity", value: "album"),
                            .init(name: "limit", value: "200"), .init(name: "country", value: storefront)]
            for album in (await json(a.url!))?["results"] as? [[String: Any]] ?? [] where album["collectionId"] != nil
                && normalise(album["collectionName"] as? String ?? "") == wantAlbum { editions.append(album) }
            if !editions.isEmpty { break }
        }
        editions.sort { ($0["collectionExplicitness"] as? String == "explicit") && ($1["collectionExplicitness"] as? String != "explicit") }
        return editions.compactMap { e in
            guard let id = e["collectionId"] as? Int else { return nil }
            let small = e["artworkUrl100"] as? String ?? ""
            return Album(id: "\(id)", name: e["collectionName"] as? String ?? "",
                         cover: URL(string: small.replacingOccurrences(of: "100x100bb", with: "2000x2000bb")))
        }
    }

    private func albumsByName(_ track: Track, strict: Bool = true) async -> [Album] {
        let normalise: (String) -> Set<String> = { strict ? self.words($0) : self.words(self.clean($0)) }
        let wantAlbum = normalise(track.album)
        guard !wantAlbum.isEmpty else { return [] }
        let viaArtist = await albumsViaArtist(track, normalise: normalise, wantAlbum: wantAlbum)
        if !viaArtist.isEmpty { return viaArtist }
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: "\(track.artist) \(clean(track.album))"), .init(name: "entity", value: "album"),
                        .init(name: "limit", value: "25"), .init(name: "country", value: storefront)]
        let matching = ((await json(c.url!))?["results"] as? [[String: Any]] ?? []).filter {
            normalise($0["collectionName"] as? String ?? "") == wantAlbum
                && !words($0["artistName"] as? String ?? "").isDisjoint(with: words(track.artist))
        }
        let wantTitle = words(clean(track.title))
        var confirmed: [String: Any]?
        for album in matching.prefix(4) {
            guard let id = album["collectionId"] as? Int else { continue }
            var l = URLComponents(string: "https://itunes.apple.com/lookup")!
            l.queryItems = [.init(name: "id", value: "\(id)"), .init(name: "entity", value: "song"), .init(name: "country", value: storefront)]
            let songs = (await json(l.url!))?["results"] as? [[String: Any]] ?? []
            if songs.contains(where: { words(clean($0["trackName"] as? String ?? "")) == wantTitle }) { confirmed = album; break }
        }
        guard let confirmed, let artistID = confirmed["artistId"] as? Int else { return [] }

        var editions = [confirmed]
        var a = URLComponents(string: "https://itunes.apple.com/lookup")!
        a.queryItems = [.init(name: "id", value: "\(artistID)"), .init(name: "entity", value: "album"),
                        .init(name: "limit", value: "200"), .init(name: "country", value: storefront)]
        for other in (await json(a.url!))?["results"] as? [[String: Any]] ?? [] {
            let id = other["collectionId"] as? Int
            if id != nil, id != confirmed["collectionId"] as? Int,
               normalise(other["collectionName"] as? String ?? "") == wantAlbum { editions.append(other) }
        }
        editions.sort { ($0["collectionExplicitness"] as? String == "explicit") && ($1["collectionExplicitness"] as? String != "explicit") }
        return editions.compactMap { e in
            guard let id = e["collectionId"] as? Int else { return nil }
            let small = e["artworkUrl100"] as? String ?? ""
            return Album(id: "\(id)", name: e["collectionName"] as? String ?? "",
                         cover: URL(string: small.replacingOccurrences(of: "100x100bb", with: "2000x2000bb")))
        }
    }

    private func findAlbums(_ track: Track) async -> [Album] {
        func fromWeb() async -> [Album] {
            let web = await webAlbums(artist: track.artist, album: track.album)
            if !web.isEmpty { Debug.log("album by Apple Music's website: \(web[0].name), \(web.count) edition(s)") }
            return web.map { Album(id: $0.id, name: $0.name, cover: $0.cover) }
        }
        // Apple Music's website first: it isn't rate-limited like the iTunes API, and it found albums the API missed.
        if !track.album.isEmpty { let web = await fromWeb(); if !web.isEmpty { return web } }
        if Date() < blockedUntil { return [] }  // the API is refusing: don't even ask
        return await findAlbumsViaAPI(track)
    }

    private func findAlbumsViaAPI(_ track: Track) async -> [Album] {
        var named = await albumsByName(track, strict: true)
        if named.isEmpty { named = await albumsByName(track, strict: false) }  // Apple adds " - Single" and the like
        if !named.isEmpty { Debug.log("album by name: \(named[0].name), \(named.count) edition(s)"); return named }
        guard let one = await findAlbumBySong(track) else { return [] }
        return [one]
    }

    private func findAlbumBySong(_ track: Track) async -> Album? {
        let songs = await search(term: "\(track.artist) \(clean(track.title))", entity: "song")
            .filter { $0["collectionId"] != nil }
        let top = songs.max(by: { score(track, $0) < score(track, $1) })
        Debug.log("itunes songs=\(songs.count) bestScore=\(top.map { score(track, $0) } ?? -1) track.album=\(track.album)")
        guard var best = top, score(track, best) >= 5 else { return nil }

        // The public search returns clean editions; the explicit one carries the motion art.
        if best["collectionExplicitness"] as? String == "cleaned", let artistID = best["artistId"] as? Int {
            var c = URLComponents(string: "https://itunes.apple.com/lookup")!
            c.queryItems = [.init(name: "id", value: "\(artistID)"), .init(name: "entity", value: "album"),
                            .init(name: "limit", value: "200"), .init(name: "country", value: storefront)]
            let name = (best["collectionCensoredName"] as? String ?? "").lowercased()
            let albums = (await json(c.url!))?["results"] as? [[String: Any]] ?? []
            if let explicit = albums.first(where: {
                $0["collectionExplicitness"] as? String == "explicit"
                    && ($0["collectionCensoredName"] as? String ?? "").lowercased() == name }) {
                best = explicit
            }
        }
        guard let id = best["collectionId"] as? Int else { return nil }
        let small = best["artworkUrl100"] as? String ?? ""
        let cover = URL(string: small.replacingOccurrences(of: "100x100bb", with: "2000x2000bb"))
        return Album(id: "\(id)", name: best["collectionName"] as? String ?? "", cover: cover)
    }

    private func musicVideoURL(_ track: Track) async -> URL? {
        let results = await search(term: "\(track.artist) \(clean(track.title))", entity: "musicVideo")
        // Exact artist and title only: never a random video.
        let match = results.first {
            words($0["artistName"] as? String ?? "") == words(track.artist)
                && words(clean($0["trackName"] as? String ?? "")) == words(clean(track.title))
        }
        return (match?["previewUrl"] as? String).flatMap(URL.init(string:))
    }

    // MARK: Motion art

    /// Apple withholds motion art from third-party tokens, but the public album page embeds it.
    /// Unofficial and may break if Apple changes the page; ship fixes through your own service.
    private func motionURL(albumID: String) async -> (url: URL?, accent: Color?) {
        if let page = webCache[albumID] { return (page.motion, nil) }  // already read from the website: no second request
        guard let page = URL(string: "https://music.apple.com/\(storefront)/album/\(albumID)") else { return (nil, nil) }
        var request = URLRequest(url: page, timeoutInterval: 20)
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { failureCount += 1; return (nil, nil) }

        var accent: Color?
        if let cover = html.range(of: "\"artwork\":{\"dictionary\":{") {
            let slice = String(html[cover.lowerBound...].prefix(400))
            if let hex = firstMatch(#""bgColor":"([0-9a-fA-F]{6})""#, in: slice) { accent = Color(hex: hex) }
        }
        for kind in ["motionDetailSquare", "motionSquareVideo1x1", "motionDetailTall", "motionTallVideo3x4"] {
            if let url = firstMatch("\"\(kind)\":\\{.*?\"video\":\"(https:[^\"]+\\.m3u8)\"", in: html) {
                return (URL(string: url), accent)
            }
        }
        return (nil, accent)
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

extension Color {
    init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}
