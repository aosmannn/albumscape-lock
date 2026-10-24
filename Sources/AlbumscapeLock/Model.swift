//
//  Model.swift
//

import AppKit
import Combine
import SwiftUI
import Foundation

/// What's playing, and the picture and video found for it. Polls once a second while someone needs it.
@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var art: AlbumArt?
    @Published private(set) var video: YouTubeVideo?
    /// Full-screen video, or the small player (click the video to shrink it, click the cover to open it again).
    @Published var expanded = true
    /// The small player's output list is open (the card grows downward to hold it).
    @Published var outputsHeight: CGFloat = 0
    /// The icon of the speaker or headphones that sound is going to, shown on the player's output button.
    @Published var outputSymbol = AudioOutputs.currentSymbol()
    /// Synced lyrics for the song, and whether to show them (the L button; remembered).
    @Published private(set) var lyrics: [LyricLine] = []
    @Published var lyricsOn: Bool = UserDefaults.standard.object(forKey: "lyrics") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lyricsOn, forKey: "lyrics") }
    }
    /// When the position was last read, so the lyrics and bars can move smoothly between the one-second reads.
    private(set) var sampledAt = Date()
    /// A short note ("Lyrics on") shown for a moment after L is pressed.
    @Published private(set) var toast: String?
    /// Whether the song is in your Spotify liked songs (needs Spotify connected).
    @Published private(set) var liked = false

    private var spotifyTrackID: String? {
        guard let id = track?.spotifyID, id.hasPrefix("spotify:track:") else { return nil }
        return String(id.dropFirst("spotify:track:".count))
    }

    /// The heart: like or unlike the song. Not connected yet: start connecting.
    func toggleLike() {
        let account = SpotifyAccount.shared
        guard account.connected else { account.connect(); return }
        if let message = account.blockedMessage { showToast(message); return }  // the heart stays as it is: nothing was saved
        guard let id = spotifyTrackID else { return }
        let want = !liked
        liked = want  // at once; put back if Spotify refuses
        Task { [weak self] in
            if await account.setLiked(id, want) == false { self?.liked = !want }
        }
    }

    /// The heart follows the saved list of your liked songs: no request to Spotify when the song changes.
    private func refreshLiked() async {
        let account = SpotifyAccount.shared
        guard account.connected, let id = spotifyTrackID else { liked = false; return }
        if !account.hasLikedList { await account.syncLiked() }
        liked = account.isLikedCached(id)
    }

    func toggleLyrics() {
        lyricsOn.toggle()
        showToast(lyricsOn ? (lyrics.isEmpty ? "Lyrics on (none found for this song)" : "Lyrics on") : "Lyrics off")
    }

    func showToast(_ text: String) {
        toast = text
        let shown = toast
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            if self?.toast == shown { self?.toast = nil }
        }
    }

    private let reader = NowPlayingReader()
    private let lookup = AlbumLookup()
    private let youtube = YouTubeFinder()
    private let lyricsFinder = LyricsFinder()

    // Nothing playing: shuffle through the albums that have animated covers (desktop and lock screen).
    @Published private(set) var idleArt: AlbumArt?
    private var idleSince: Date?
    private var idleTask: Task<Void, Never>?
    static var idleShuffleOn: Bool { UserDefaults.standard.object(forKey: "idleShuffle") as? Bool != false }
    /// What the screen shows: the shuffled animation while idle, else the song's own art.
    var displayArt: AlbumArt? { idleArt ?? art }

    /// The shuffle was turned off in Settings: stop it now.
    func skipIdleOff() { updateIdle() }

    /// The next animated cover in the idle shuffle, now.
    func skipIdle() {
        guard idleArt != nil else { return }
        idleTask?.cancel()
        idleTask = nil
        updateIdle()
    }

    private func updateIdle() {
        if track?.isPlaying == true || !Self.idleShuffleOn {
            idleSince = nil
            idleTask?.cancel(); idleTask = nil
            if idleArt != nil { idleArt = nil }
            return
        }
        if idleSince == nil { idleSince = Date() }
        guard idleTask == nil, let since = idleSince, Date().timeIntervalSince(since) >= 8 else { return }  // paused for a moment isn't idle
        idleTask = Task { [weak self] in
            var last: URL?
            while !Task.isCancelled {
                guard let self else { return }
                guard let pick = AlbumDB.shared.randomMotion(excluding: last) else { self.idleTask = nil; return }
                var shown = AlbumArt(album: pick.album)
                shown.motionURL = pick.url
                self.idleArt = shown
                last = pick.url
                Debug.log("idle shuffle: \(pick.album)")
                try? await Task.sleep(for: .seconds(AlbumDB.Daypart.now == .night ? 150 : 75))  // slower at night
            }
        }
    }

    /// Menu bar > Music videos. Off: only the album's animated cover (or the still cover), never a video.
    /// Settings > Music videos: "always" (the video first), "noMotion" (only when the album has no animation) or "off".
    static var videoMode: String {
        if let mode = UserDefaults.standard.string(forKey: "videoMode") { return mode }
        return UserDefaults.standard.object(forKey: "musicVideos") as? Bool == false ? "off" : "always"
    }
    static var videosAllowed: Bool { videoMode != "off" && !Power.saving }
    private var poll: Task<Void, Never>?
    private var connectedWatch: AnyCancellable?

    /// The song's position now, counting on from the last read while it plays.
    /// The clock runs on its own from an anchor and is only moved when a read disagrees by more than 0.45 s (a seek, a
    /// pause, a new song): correcting it on every one-second read made the lyrics and bars hop back and forth.
    func position(at date: Date) -> TimeInterval {
        guard let t = track else { return 0 }
        guard t.isPlaying else { return anchorPosition }
        return min(t.duration > 0 ? t.duration : .infinity, anchorPosition + date.timeIntervalSince(anchorDate))
    }
    private var wantedPlaying: (value: Bool, until: Date)?
    private var seekHoldUntil = Date.distantPast
    /// Dragging the progress bar: the clock jumps at once and a read that still shows the old spot is ignored for a moment.
    func seek(to seconds: TimeInterval) {
        guard let t = track, t.duration > 0, t.source != LastFM.bundle else { return }
        let target = min(max(0, seconds), t.duration - 0.5)
        anchorPosition = target; anchorDate = Date()
        seekHoldUntil = Date().addingTimeInterval(1.5)
        reader.seek(to: target, source: t.source)
        refreshSoon([0.4, 1.0])
    }
    private var anchorPosition: TimeInterval = 0
    private var anchorDate = Date()

    // The buttons answer at once and then check with the player, instead of waiting for the next one-second read.
    func playPause() {
        if var t = track {  // the symbol flips now, and the clock holds or runs on
            anchorPosition = position(at: Date()); anchorDate = Date()
            t.isPlaying.toggle(); sampledAt = Date(); track = t
            // The player takes a moment to change; until it agrees (or 1.5 s pass) a read that still says the old
            // state must not flip the symbol back, which made pause and play look like they happened twice.
            wantedPlaying = (t.isPlaying, Date().addingTimeInterval(1.5))
        }
        reader.command("playpause", source: track?.source ?? "")
        refreshSoon([0.25, 0.9])
    }
    func next() { reader.command("next track", source: track?.source ?? ""); refreshSoon([0.3, 0.8, 1.6]) }
    func previous() { reader.command("previous track", source: track?.source ?? ""); refreshSoon([0.3, 0.8, 1.6]) }

    private func refreshSoon(_ delays: [Double]) {
        Task { [weak self] in
            for d in delays {
                try? await Task.sleep(for: .seconds(d))
                await self?.tick()
            }
        }
    }

    func start() {
        guard poll == nil else { return }
        connectedWatch = SpotifyAccount.shared.$connected.dropFirst().sink { [weak self] _ in Task { await self?.refreshLiked() } }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }

    func stop() {
        poll?.cancel()
        poll = nil
    }

    private func tick() async {
        var now = await reader.read()
        if let wanted = wantedPlaying {
            if now?.isPlaying == wanted.value || Date() > wanted.until { wantedPlaying = nil }
            else if now != nil { now?.isPlaying = wanted.value }
        }
        let changedSong = now?.key != track?.key
        sampledAt = Date()
        if let n = now {
            let predicted = anchorPosition + (n.isPlaying ? Date().timeIntervalSince(anchorDate) : 0)
            if changedSong || track?.isPlaying != n.isPlaying || (Date() >= seekHoldUntil && (!n.isPlaying || abs(n.position - predicted) > 0.45)) {
                anchorPosition = n.position
                anchorDate = Date()
            }
        }
        if now != track { track = now }
        let symbol = AudioOutputs.currentSymbol()
        if symbol != outputSymbol { outputSymbol = symbol }
        updateIdle()
        guard changedSong else { return }
        // The last song's cover and colour stay until the new ones are ready (no blank, no white flash); only its video and
        // animation go.
        art = art.map { last in var keep = AlbumArt(album: now?.album ?? ""); keep.coverURL = last.coverURL; keep.accent = last.accent; return keep }
        video = nil
        lyrics = []
        liked = false
        Task { [weak self] in await self?.refreshLiked() }
        if let now {
            Task { [weak self] in
                guard let self else { return }
                let lines = await self.lyricsFinder.lyrics(for: now) ?? []
                if self.track?.key == now.key { self.lyrics = lines; Debug.log("lyrics: \(lines.count) lines") }
            }
        }
        guard let now else { return }
        // The lookups run on their own, so the next skip is noticed at once instead of waiting for them; a newer song
        // cancels the older song's work.
        songTask?.cancel()
        songTask = Task { [weak self] in await self?.loadSong(now) }
    }

    private var songTask: Task<Void, Never>?

    /// Puts the picture on screen with the song's saved colour, whichever step of the lookup got there.
    private func publish(_ art: AlbumArt?, for now: Track) {
        guard track?.key == now.key else { return }
        var shown = art
        if let saved = AlbumDB.shared.accent(for: now) { shown?.accent = saved }
        self.art = shown
    }

    private func loadSong(_ now: Track) async {
        Debug.log("track: \(now.key) (\(now.album))")
        AlbumDB.shared.noteListened(now)
        // The video lookup waits a moment first, so skipping through several songs only looks up the one you land on.
        let clipTask = Task<YouTubeVideo?, Never> { [youtube] in
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled || !Self.videosAllowed { return nil }
            // something playing in a browser (or any other app the system reports): its picture only, never a video
            if now.source == SystemNowPlaying.bundle { return nil }
            return await youtube.video(for: now)
        }
        defer { clipTask.cancel() }
        let ownCover = Self.quickCover(now.artworkURL)
        // Spotify's cover leads (it is the exact artwork); a browser's picture is only the fallback when no album is found
        let spotifyCover = now.source == SystemNowPlaying.bundle ? nil : ownCover
        // The colour first of all: the one saved for this album, else the last song's (so it never drops to white), and
        // the real one worked out from the cover at once, in parallel with everything else.
        let carried = AlbumDB.shared.accent(for: now) ?? self.art?.accent
        let colourTask = Task { @MainActor [weak self] in
            guard let self, AlbumDB.shared.accent(for: now) == nil, let cover = spotifyCover, let c = await CoverColor.vivid(from: cover) else { return }
            AlbumDB.shared.setAccent(c, for: now)
            if self.track?.key == now.key { withAnimation(.easeInOut(duration: 0.5)) { self.art?.accent = c } }
        }
        defer { _ = colourTask }
        var art: AlbumArt?
        var incomplete = false
        // A known album starts at once from what was saved; only a new one is looked up.
        switch AlbumDB.shared.answer(for: now) {
        case .motion(let url):
            var known = AlbumArt(album: now.album); known.motionURL = url; known.coverURL = spotifyCover; known.accent = carried
            art = known
            publish(known, for: now)
        case .none where spotifyCover != nil:
            var known = AlbumArt(album: now.album); known.coverURL = spotifyCover; known.accent = carried
            art = known
            publish(known, for: now)
        default:
            if let cover = spotifyCover {  // the cover shows now; the lookup (which can take a while) adds the animation
                var quick = AlbumArt(album: now.album); quick.coverURL = cover; quick.accent = carried
                publish(quick, for: now)
            }
            try? await Task.sleep(for: .milliseconds(300))  // skipping fast: only the song you land on is looked up
            if Task.isCancelled { return }
            // the song you're listening to goes to the front of Apple's queue, not behind background work
            let found = await LookupLane.$foreground.withValue(true) { await self.lookup.art(for: now) }
            art = found
            // Keep the cover that is already on screen (Spotify's): Apple's can be a different crop of the artwork, and
            // swapping to it a moment later showed as a flash.
            if let cover = spotifyCover { var same = art ?? AlbumArt(album: now.album); same.coverURL = cover; art = same }
            if Task.isCancelled { return }
            incomplete = found?.complete == false
            if art?.coverURL == nil, now.source == SystemNowPlaying.bundle {
                // a browser's picture is small: look for a sharp one (the video's own thumbnail, or Apple's artwork)
                let tab = await SystemNowPlaying.shared.videoID(for: now)
                let page = await SystemNowPlaying.shared.tabURL(for: now)
                if let sharp = await HighQualityArt.find(for: now, videoID: tab, pageURL: page) {
                    var better = art ?? AlbumArt(album: now.album)
                    better.coverURL = sharp
                    art = better
                    Debug.log("sharp artwork for \(now.key): \(sharp.lastPathComponent)")
                }
            }
            if art?.coverURL == nil, let cover = ownCover {
                var fallback = art ?? AlbumArt(album: now.album)  // Spotify's own cover, when the album lookup finds nothing
                fallback.coverURL = cover
                art = fallback
            }
            if art?.motionURL == nil, let shared = SharedAnswers.motion(for: now) {
                var withShared = art ?? AlbumArt(album: now.album)
                withShared.motionURL = shared
                art = withShared
                Debug.log("motion art from the helper's saved answers")
            }
            if !incomplete { AlbumDB.shared.remember(now, motion: art?.motionURL) }
            publish(art, for: now)  // the picture and animation show before the colour is worked out
        }
        // The quick 640-pixel cover shows first; the full-size one replaces it once it has downloaded, so the cover is
        // sharp full screen.
        if let quick = art?.coverURL, quick.absoluteString.contains("ab67616d0000b273"), let large = Self.largeCover(now.artworkURL),
           (try? await URLSession.shared.data(from: large)) != nil, !Task.isCancelled, track?.key == now.key {
            art?.coverURL = large
            self.art = art
        }
        if AlbumDB.shared.accent(for: now) == nil, let cover = art?.coverURL, let accent = await CoverColor.vivid(from: cover) {  // the cover's own colour, not Apple's text colours
            AlbumDB.shared.setAccent(accent, for: now)
            art?.accent = accent
            publish(art, for: now)
        }
        if let cover = art?.coverURL, let b = await CoverColor.brightness(from: cover) { AlbumDB.shared.setBrightness(b, for: now) }
        Debug.log("art: cover=\(art?.coverURL != nil) motion=\(art?.motionURL != nil)")
        if incomplete { retryLookup(now) }
        let clipFound = await clipTask.value
        if Task.isCancelled { return }
        if track?.key == now.key { video = clipFound }
        Debug.log("youtube: \(clipFound?.id ?? "none")")
    }

    /// The Music videos setting changed: look for (or drop) this song's video now.
    func videoSettingChanged() {
        guard let song = track else { return }
        if !Self.videosAllowed || song.source == SystemNowPlaying.bundle { video = nil; return }
        Task { [weak self] in
            guard let self else { return }
            let found = await self.youtube.video(for: song)
            if self.track?.key == song.key { self.video = found }
        }
    }

    /// Apple didn't answer fully (refusing, or no network): "no animation" must not be taken for "unknown", so ask again.
    private func retryLookup(_ song: Track) {
        Task { [weak self] in
            for delay in [12.0, 30, 90] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.track?.key == song.key else { return }
                guard let again = await LookupLane.$foreground.withValue(true, operation: { await self.lookup.art(for: song) }), again.complete else { continue }
                AlbumDB.shared.remember(song, motion: again.motionURL)
                if let url = again.motionURL, self.track?.key == song.key {
                    var updated = self.art ?? again
                    updated.motionURL = url
                    self.art = updated
                    Debug.log("motion art found on retry")
                }
                return
            }
        }
    }

    /// The 640-pixel cover (about 60 KB): it is on screen almost at once; the full-size one is far larger.
    static func quickCover(_ address: String) -> URL? {
        guard !address.isEmpty else { return nil }
        return URL(string: address.replacingOccurrences(of: "ab67616d00001e02", with: "ab67616d0000b273"))
    }

    /// Spotify's cover address names a size; ab67616d000082c1 is the largest, so a still fills the screen sharply.
    static func largeCover(_ address: String) -> URL? {
        guard !address.isEmpty else { return nil }
        let large = address.replacingOccurrences(of: "ab67616d0000b273", with: "ab67616d000082c1")
            .replacingOccurrences(of: "ab67616d00001e02", with: "ab67616d000082c1")
        return URL(string: large)
    }
}
