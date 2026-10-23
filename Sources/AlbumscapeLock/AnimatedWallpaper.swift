//
//  AnimatedWallpaper.swift
//
//  Plays the animated cover of the song playing on a window that sits on the desktop: above the wallpaper, below the
//  icons and every app. Normal window calls only. Albums with no animation keep the still wallpaper (Wallpaper.swift).
//  `defaults write com.adam.albumscape-lock animatedWallpaper -bool false` turns it off.
//

import AppKit
import AVFoundation

@MainActor
final class AnimatedWallpaper {
    static let shared = AnimatedWallpaper()

    static var enabled: Bool {
        let suite = UserDefaults(suiteName: "com.adam.albumscape-lock")?.object(forKey: "animatedWallpaper") as? Bool
        return (suite ?? UserDefaults.standard.object(forKey: "animatedWallpaper") as? Bool) != false
    }

    private var windows: [NSWindow] = []
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var current: String?
    private var observing = false

    private var generation = 0

    /// Starts `link` on the desktop. The picture already showing stays until the new one has its first frame, then they
    /// cross-fade, so a song change never flashes black.
    func show(_ link: String) {
        guard Self.enabled, let url = URL(string: link) else { hide(); return }
        observeScreens()
        // Already showing this one, or still loading it: leave it be. (Starting it again on every check, before it had a
        // frame, meant it never got one, and left invisible windows piling up.)
        if link == current { if !windows.isEmpty { player?.play() }; return }
        dropPending()
        current = link
        generation += 1
        let mine = generation
        let queue = AVQueuePlayer()
        queue.isMuted = true
        let item = AVPlayerItem(url: url)
        let newLooper = AVPlayerLooper(player: queue, templateItem: item)
        var fresh: [NSWindow] = []
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.alphaValue = 0
            let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            let layer = AVPlayerLayer(player: queue)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(layer)
            window.contentView = view
            window.orderFront(nil)
            fresh.append(window)
        }
        queue.play()
        pendingWindows = fresh
        pendingPlayer = queue
        let oldWindows = windows, oldPlayer = player, oldLooper = looper
        pendingLoad = layerReadyObserver(for: queue) { [weak self] in
            guard let self, self.generation == mine else { return }
            self.pendingWindows = []
            self.pendingPlayer = nil
            self.windows = fresh
            self.player = queue
            self.looper = newLooper
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                fresh.forEach { $0.animator().alphaValue = 1 }
            }, completionHandler: {
                oldPlayer?.pause()
                oldWindows.forEach { $0.orderOut(nil) }
                _ = oldLooper
            })
            Debug.log("animated wallpaper: playing")
        }
    }

    private var pendingLoad: NSKeyValueObservation?
    private var pendingWindows: [NSWindow] = []
    private var pendingPlayer: AVQueuePlayer?

    /// A load that hasn't shown yet and is no longer wanted: stop it and take its windows away.
    private func dropPending() {
        pendingLoad = nil
        pendingPlayer?.pause()
        pendingPlayer = nil
        pendingWindows.forEach { $0.orderOut(nil) }
        pendingWindows = []
    }

    /// Calls `ready` once the player has a frame to show.
    private func layerReadyObserver(for queue: AVQueuePlayer, ready: @escaping () -> Void) -> NSKeyValueObservation {
        var fired = false
        return queue.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
            guard !fired, player.timeControlStatus == .playing else { return }
            fired = true
            DispatchQueue.main.async { ready() }
        }
    }

    func pause() { player?.pause() }

    func hide() {
        generation += 1  // a load still in flight is dropped
        dropPending()
        guard current != nil || !windows.isEmpty else { return }
        tearDown()
        Debug.log("animated wallpaper: stopped")
    }

    private func tearDown() {
        player?.pause()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        looper = nil
        player = nil
        current = nil
    }

    private func observeScreens() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let link = self.current else { return }
                self.tearDown()
                self.show(link)  // a screen was added, removed or resized
            }
        }
    }
}
