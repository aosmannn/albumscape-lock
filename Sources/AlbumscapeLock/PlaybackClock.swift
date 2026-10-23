//
//  PlaybackClock.swift
//
//  The lock screen's video and the desktop's animation are two players. Whichever is showing writes down where it is in
//  the video; the other, when it starts the same video, jumps to that place (plus the time that has passed), so going
//  from the lock screen to the desktop at unlock (or back) carries on from the same frame instead of jumping.
//

import AVFoundation
import Foundation

@MainActor
final class PlaybackClock {
    static let shared = PlaybackClock()
    private var seen: [String: (time: Double, duration: Double, at: Date)] = [:]

    func note(_ url: URL, time: Double, duration: Double) {
        guard time.isFinite, duration.isFinite, duration > 1 else { return }
        seen[url.absoluteString] = (time, duration, Date())
    }

    /// Where this video would be now, if one of the players had it within the last half minute.
    func position(of url: URL) -> CMTime? {
        guard let s = seen[url.absoluteString], Date().timeIntervalSince(s.at) < 30 else { return nil }
        let t = (s.time + Date().timeIntervalSince(s.at)).truncatingRemainder(dividingBy: s.duration)
        return CMTime(seconds: t, preferredTimescale: 600)
    }
}
