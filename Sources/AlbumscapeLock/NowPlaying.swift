//
//  NowPlaying.swift
//  Albumscape
//
//  DroppyKit 1.20 has no now-playing service (`media-read` is declared but
//  unbacked), so this asks Spotify and Music directly over Apple events.
//

import AppKit

struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var position: TimeInterval
    var duration: TimeInterval
    var artworkURL = ""  // the player's own cover address (Spotify gives one), for when the album lookup finds nothing
    var spotifyID = ""  // "spotify:track:..." when the song is playing in Spotify
    var source = ""  // bundle id of the player, so the controls reach the right one

    /// Same song, whatever the playback state.
    var key: String { "\(artist)|\(title)".lowercased() }
}

@MainActor
final class NowPlayingReader {
    private struct Source {
        let bundleID: String
        let script: String
        let durationIsMilliseconds: Bool
    }

    private let sources = [
        Source(bundleID: "com.spotify.client", script: """
            tell application "Spotify"
                if player state is stopped then return ""
                return (name of current track) & "\\n" & (artist of current track) & "\\n" & (album of current track) & "\\n" & (player state as string) & "\\n" & (player position as string) & "\\n" & (duration of current track as string) & "\\n" & (artwork url of current track) & "\\n" & (id of current track)
            end tell
            """, durationIsMilliseconds: true),
        Source(bundleID: "com.apple.Music", script: """
            tell application "Music"
                if player state is stopped then return ""
                return (name of current track) & "\\n" & (artist of current track) & "\\n" & (album of current track) & "\\n" & (player state as string) & "\\n" & (player position as string) & "\\n" & (duration of current track as string)
            end tell
            """, durationIsMilliseconds: false)
    ]

    private let queue = DispatchQueue(label: "albumscape.applescript")

    /// The track from whichever player is playing, else the first that has one.
    func read() async -> Track? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var paused: Track?
        for source in sources where running.contains(source.bundleID) {  // never launch a player by asking it
            guard let track = await run(source) else { continue }
            if track.isPlaying { return track }
            paused = paused ?? track
        }
        // Nothing playing in Spotify or Music: whatever else the Mac is playing (a browser video, Tidal...).
        if let system = SystemNowPlaying.shared.read(), system.isPlaying || paused == nil { return system }
        if paused == nil { return await LastFM.shared.nowPlaying() }  // nothing at all: whatever Last.fm says is playing
        return paused
    }

    /// "playpause", "next track" or "previous track" to the player the song is coming from.
    func command(_ verb: String, source: String) {
        guard !source.isEmpty, source != LastFM.bundle else { return }
        if source == SystemNowPlaying.bundle {
            SystemNowPlaying.shared.send(["playpause": "toggle", "next track": "next", "previous track": "prev"][verb] ?? "")
            return
        }
        queue.async { _ = NSAppleScript(source: "tell application id \"\(source)\" to \(verb)")?.executeAndReturnError(nil) }
    }

    /// Moves the song to `seconds`, in the player it's coming from (Spotify and Music both take `set player position`).
    func seek(to seconds: Double, source: String) {
        guard !source.isEmpty, source != LastFM.bundle else { return }
        if source == SystemNowPlaying.bundle { SystemNowPlaying.shared.send("seek \(String(format: "%.2f", seconds))"); return }
        let script = "tell application id \"\(source)\" to set player position to \(String(format: "%.2f", seconds))"
        queue.async { _ = NSAppleScript(source: script)?.executeAndReturnError(nil) }
    }

    private func run(_ source: Source) async -> Track? {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source.script)?.executeAndReturnError(&error)
                guard let text = result?.stringValue, !text.isEmpty else {
                    if let error { Debug.log("applescript \(source.bundleID) error: \(error)") }
                    continuation.resume(returning: nil)
                    return
                }
                let parts = text.components(separatedBy: "\n")
                guard parts.count >= 6 else {
                    continuation.resume(returning: nil)
                    return
                }
                // AppleScript formats numbers with the user's locale ("1,5").
                func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
                let duration = number(parts[5]) / (source.durationIsMilliseconds ? 1000 : 1)
                continuation.resume(returning: Track(
                    title: parts[0], artist: parts[1], album: parts[2],
                    isPlaying: parts[3] == "playing",
                    position: number(parts[4]), duration: duration,
                    artworkURL: parts.count > 6 ? parts[6] : "",
                    spotifyID: parts.count > 7 ? parts[7] : "", source: source.bundleID))
            }
        }
    }
}
