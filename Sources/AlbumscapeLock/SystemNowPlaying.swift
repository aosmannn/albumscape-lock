import AppKit

/// Whatever the Mac itself says is playing, from any app: a video or song in a browser tab, Tidal, a podcast. A small
/// helper library (Native/mediaremote.m) runs inside /usr/bin/perl, which macOS allows to read it, and prints one line a
/// second; this reads them and sends play, pause, next, back and seek the other way. It starts when first asked.
@MainActor
final class SystemNowPlaying {
    static let shared = SystemNowPlaying()
    static let bundle = "system"  // Track.source for songs from here
    static var enabled: Bool { UserDefaults.standard.object(forKey: "systemSource") as? Bool ?? true }

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var latest: [String: Any]?
    private var lastLine = Date.distantPast
    private var started = false
    private var failures = 0

    private var libraryURL: URL? { Bundle.main.url(forResource: "mediaremote", withExtension: "dylib") }

    /// The playing (or paused) track from the system, or nil.
    func read() -> Track? {
        guard Self.enabled else { return nil }
        start()
        guard let d = latest, Date().timeIntervalSince(lastLine) < 4, let raw = d["title"] as? String, !raw.isEmpty else { return nil }
        let app = d["app"] as? String ?? ""
        var title = raw, artist = d["artist"] as? String ?? ""
        if app != "com.spotify.client", app != "com.apple.Music" { (title, artist) = Self.tidy(title: raw, artist: artist) }
        return Track(title: title, artist: artist, album: d["album"] as? String ?? "",
                     isPlaying: d["playing"] as? Bool ?? false, position: d["elapsed"] as? Double ?? 0,
                     duration: d["duration"] as? Double ?? 0, artworkURL: (d["art"] as? String).map { URL(fileURLWithPath: $0).absoluteString } ?? "",
                     source: Self.bundle, appBundle: app, rawTitle: raw)
    }

    /// A video site's title is "Artist - Song (Official Video)" and its "artist" the channel ("ArtistVEVO", "Artist - Topic"):
    /// pull the artist and the song out, so the album, lyrics and video can be found like any other song.
    static func tidy(title: String, artist: String) -> (String, String) {
        var t = title, a = artist
        for suffix in [" - Topic", "VEVO", " Official", "Official"] where a.hasSuffix(suffix) { a = String(a.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces) }
        let noise = try? NSRegularExpression(pattern: #"\s*[\(\[][^\)\]]*(official|lyric|audio|video|visuali[sz]er|music|hd|4k|explicit|remaster)[^\)\]]*[\)\]]"#, options: .caseInsensitive)
        if let noise { t = noise.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "") }
        t = t.replacingOccurrences(of: #"\s*\|.*$"#, with: "", options: .regularExpression)
        if let dash = t.range(of: " - ") {
            let left = String(t[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(t[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !left.isEmpty, !right.isEmpty { a = left; t = right }
        }
        return (t.trimmingCharacters(in: .whitespaces), a)
    }

    private var videoIDs: [String: String?] = [:]

    /// The YouTube video this song is playing as, found from the browser tab that has that title open (the tab's
    /// address names the video). nil for anything that isn't YouTube, or when no tab matches.
    func videoID(for track: Track) async -> String? {
        let key = track.rawTitle + "|" + track.appBundle
        if let known = videoIDs[key] { return known }
        let address = await tabURL(for: track)
        let id = address.flatMap { BrowserTabs.videoID(in: $0) }
        videoIDs[key] = id
        Debug.log("browser tab video: \(id ?? "none") for \(track.rawTitle)")
        return id
    }

    private var tabURLs: [String: String?] = [:]
    /// The address of the browser tab playing this (cached per title).
    func tabURL(for track: Track) async -> String? {
        let key = track.rawTitle + "|" + track.appBundle
        if let known = tabURLs[key] { return known }
        let address = await BrowserTabs.tabURL(title: track.rawTitle, bundle: track.appBundle)
        tabURLs[key] = address
        return address
    }

    func send(_ command: String) {
        guard let input, let data = (command + "\n").data(using: .utf8) else { return }
        try? input.write(contentsOf: data)
    }

    private func start() {
        guard !started, failures < 4, let lib = libraryURL else { return }
        started = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "use DynaLoader; DynaLoader::dl_load_file($ARGV[0], 0) or die; sleep;", lib.path]
        let out = Pipe(), inn = Pipe()
        p.standardOutput = out
        p.standardInput = inn
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            Task { @MainActor in self?.take(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                Debug.log("system now playing: helper ended")
                self.started = false; self.process = nil; self.input = nil; self.failures += 1
            }
        }
        do {
            try p.run()
            process = p; input = inn.fileHandleForWriting
            Debug.log("system now playing: helper started")
        } catch { started = false; failures += 1; Debug.log("system now playing: couldn't start (\(error))") }
    }

    private func take(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            lastLine = Date()
            if latest?["title"] as? String != obj["title"] as? String { Debug.log("system now playing: \((obj["title"] as? String) ?? "nothing") [\((obj["app"] as? String) ?? "?")] \((obj["timeout"] as? Bool) == true ? "(timed out)" : "")") }
            latest = obj
        }
    }
}

/// Asks a browser which of its tabs has a given title open, and reads that tab's address. (Chromium browsers and Safari
/// can be asked this through Automation without any extra setting; macOS asks once to allow it.)
enum BrowserTabs {
    /// The address of the tab that has this title open, or nil.
    static func tabURL(title: String, bundle: String) async -> String? {
        guard !bundle.isEmpty, !title.isEmpty, NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundle }) else { return nil }
        let safari = bundle == "com.apple.Safari"
        let script = """
        tell application id "\(bundle)"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (\(safari ? "name" : "title") of t) & tab & (URL of t) & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
        let text: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var error: NSDictionary?
                let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
                if let error { Debug.log("browser tabs: \(error[NSAppleScript.errorMessage] ?? error)") }
                continuation.resume(returning: result?.stringValue)
            }
        }
        guard let text else { return nil }
        let wanted = title.lowercased()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].lowercased().contains(wanted) || wanted.contains(parts[0].lowercased().replacingOccurrences(of: " - youtube", with: "")) else { continue }
            return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func videoID(in address: String) -> String? {
        guard let url = URL(string: address), let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix("youtube.com") {
            if url.path == "/watch", let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value { return id }
            if url.path.hasPrefix("/shorts/") { return String(url.path.dropFirst(8)) }
        }
        if host == "youtu.be" { return String(url.path.dropFirst()) }
        return nil
    }
}

/// A sharp picture for something playing in a browser. The page only hands over a small one (a few hundred pixels, which
/// looks soft full screen), so: for a YouTube video its real thumbnail; for another page the large picture the page names
/// for sharing (og:image); else Apple's own artwork for the show, film or song, if it really is that.
enum HighQualityArt {
    static func find(for track: Track, videoID: String?, pageURL: String?) async -> URL? {
        if let id = videoID {
            for name in ["maxresdefault", "sddefault", "hqdefault"] {
                guard let url = URL(string: "https://i.ytimg.com/vi/\(id)/\(name).jpg") else { continue }
                var request = URLRequest(url: url, timeoutInterval: 8)
                request.httpMethod = "HEAD"
                if let (_, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 { return url }
            }
        }
        if let pageURL, let image = await pageImage(pageURL) { return image }
        return await appleArtwork(for: track)
    }

    /// The picture a page names for link previews: <meta property="og:image" content="...">.
    private static func pageImage(_ address: String) async -> URL? {
        guard let url = URL(string: address), url.scheme == "https" || url.scheme == "http" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data.prefix(400_000), encoding: .utf8),
              let tag = try? NSRegularExpression(pattern: #"<meta[^>]+property=["']og:image["'][^>]*>"#, options: .caseInsensitive),
              let hit = tag.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(hit.range, in: html),
              let content = try? NSRegularExpression(pattern: #"content=["']([^"']+)["']"#).firstMatch(in: String(html[range]), range: NSRange(html[range].startIndex..., in: html[range])),
              let cr = Range(content.range(at: 1), in: String(html[range])) else { return nil }
        let value = String(String(html[range])[cr]).replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: value, relativeTo: url)?.absoluteURL
    }

    private static func normal(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    private static func appleArtwork(for track: Track) async -> URL? {
        // a show's name is its "artist", the episode its title; a song has both
        let queries: [(term: String, media: String, entity: String)] = [
            (track.artist, "tvShow", "tvSeason"), (track.artist, "movie", "movie"),
            ([track.artist, track.title].filter { !$0.isEmpty }.joined(separator: " "), "music", "song"),
        ]
        let names = [normal(track.artist), normal(track.title)].filter { $0.count >= 3 }
        for query in queries where !query.term.isEmpty {
            var parts = URLComponents(string: "https://itunes.apple.com/search")!
            parts.queryItems = [.init(name: "term", value: query.term), .init(name: "media", value: query.media),
                                .init(name: "entity", value: query.entity), .init(name: "limit", value: "3")]
            guard let url = parts.url, let (data, _) = try? await URLSession.shared.data(from: url),
                  let results = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]] else { continue }
            // only a result that really is this: its names must contain the show's or the song's
            for r in results {
                let fields = ["artistName", "collectionName", "trackName"].compactMap { r[$0] as? String }.map(normal)
                guard let small = r["artworkUrl100"] as? String, names.contains(where: { n in fields.contains { $0.contains(n) || n.contains($0) && $0.count >= 4 } }) else { continue }
                return URL(string: small.replacingOccurrences(of: "100x100bb", with: "1200x1200bb"))
            }
        }
        return nil
    }
}
