//
//  main.swift
//  Albumscape Lock: a menu bar app that shows the playing song's music video, or motion art, full screen on the
//  macOS lock screen. `AlbumscapeLock --preview` shows it on the desktop for 20 seconds, for testing.
//

import AppKit
import Combine
import IOKit.pwr_mgt
import ServiceManagement
import SwiftUI

/// Takes the first click even though the window isn't the key window.
final class TapHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Set on the full-screen video: a click in the top-left corner (the L badge) and a click anywhere else are told apart
    /// here, in view coordinates measured from the top, rather than by a SwiftUI gesture whose coordinates drifted.
    var onBadgeClick: (() -> Void)?
    var onBackgroundClick: (() -> Void)?

    /// The full-screen video's web view would otherwise take the click for itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onBackgroundClick != nil else { return super.hitTest(point) }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let background = onBackgroundClick else { super.mouseDown(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        let fromTop = isFlipped ? p.y : bounds.height - p.y
        Debug.log("full-screen click at \(Int(p.x)),\(Int(fromTop))")
        if p.x < LyricsBadge.hitSize.width, fromTop < LyricsBadge.hitSize.height { onBadgeClick?() } else { background() }
    }
}

@MainActor
final class Overlay {
    private var windows: [NSWindow] = []
    private let model: PlayerModel
    /// Where our space sits among the lock screen's own layers. Droppy's overlays sit in theirs: if this covers
    /// Droppy's widgets, lower it with `defaults write com.adam.albumscape-lock level -int <n>`.
    private var level: Int32 {
        let saved = UserDefaults.standard.object(forKey: "level") as? Int
        return Int32(saved ?? 350)  // above the lock UI's spaces (300), below Droppy's overlay space (400, 0x190), so its mini player stays on top
    }

    /// On the lock screen the window must sit under the lock UI (the clock, your profile: loginwindow draws it at
    /// levels 2001 and 2004) so it plays behind them like a wallpaper. Change it with
    /// `defaults write com.adam.albumscape-lock windowLevel -int <n>`.
    private var windowLevel: Int { (UserDefaults.standard.object(forKey: "windowLevel") as? Int) ?? Int(CGShieldingWindowLevel()) }

    /// Called when the overlay is tapped: it steps aside so Droppy's own lock screen player is there.
    var onDismiss: () -> Void = {}

    init(model: PlayerModel) { self.model = model }

    /// Holds the display on while the overlay is up (macOS turns it off a few seconds after locking), as Droppy's
    /// "Keep screen awake" does. Released the moment the overlay goes away.
    private var awake: IOPMAssertionID = 0

    private func keepAwake(_ on: Bool) {
        if on, awake == 0 {
            let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Albumscape Lock: showing the music video" as CFString, &awake)
            Debug.log("keep awake: \(result == kIOReturnSuccess ? "on" : "failed \(result)")")
        } else if !on, awake != 0 {
            IOPMAssertionRelease(awake)
            awake = 0
        }
    }

    var isShowing: Bool { !windows.isEmpty }

    private var screens: [NSScreen] = []
    private var infoWindows: [NSWindow] = []
    private var modeWatch: AnyCancellable?

    func show(onLockScreen: Bool) {
        guard windows.isEmpty else { return }
        model.expanded = true
        model.start()
        screens = NSScreen.screens
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = true
            window.backgroundColor = .black
            window.level = NSWindow.Level(rawValue: onLockScreen ? windowLevel : Int(CGShieldingWindowLevel()))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.ignoresMouseEvents = onLockScreen == false
            let full = TapHostingView(rootView: FullScreenView(model: model))
            full.onBadgeClick = { [model] in model.toggleLyrics() }
            full.onBackgroundClick = { [model] in if model.idleArt == nil { model.expanded = false } else { model.skipIdle() } }  // the idle shuffle has no player to shrink to: a click skips to the next cover
            window.contentView = full
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            if onLockScreen {
                // A background by default (the lock screen's own space, under the clock); `defaults write
                // com.adam.albumscape-lock overlay -bool true` brings back the old cover-everything window.
                if UserDefaults.standard.string(forKey: "mode") == "active", LockSpace.attachToActiveSpace(window) {}
                else { LockSpace.attach(window, level: level) }
            }
            windows.append(window)

            // The song info lives in a clear window just above the video's (see InfoOverlayView); clicks pass through.
            let info = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            info.isReleasedWhenClosed = false
            info.isOpaque = false
            info.backgroundColor = .clear
            info.hasShadow = false
            info.ignoresMouseEvents = true
            info.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
            info.collectionBehavior = window.collectionBehavior
            info.contentView = NSHostingView(rootView: InfoOverlayView(model: model))
            info.setFrame(screen.frame, display: true)
            info.orderFrontRegardless()
            if onLockScreen { LockSpace.attach(info, level: level) }
            infoWindows.append(info)
        }
        if onLockScreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Self.logWindows() }
        }
        for delay in [6.0, 14.0] {  // a picture of our own window, so what it really contains can be looked at
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let window = self?.windows.first else { return }
                Self.snapshot(window, name: "\(onLockScreen ? "lock" : "preview")-\(Int(delay))s")
            }
        }
        if onLockScreen {
            keepAwake(true)
            // The lock screen creates its own space when it appears (it has the wallpaper and the clock). Move our
            // window into it at a level between the two, so the video plays as the background, not over the clock.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                let fresh = LockSpace.newSpaces()
                Debug.log("new spaces at lock: \(fresh.map { "\($0.id)=\($0.level)" }.joined(separator: " "))")
                guard UserDefaults.standard.string(forKey: "mode") == "lockspace",
                      let lock = fresh.filter({ $0.level < 400 }).max(by: { $0.id < $1.id }) else { return }
                for window in self?.windows ?? [] { LockSpace.move(window, toSpace: lock.id) }
                Debug.log("window moved into lock space \(lock.id) (level \(lock.level)) at window level \(self?.windowLevel ?? 0)")
            }
        }
        modeWatch = model.$expanded.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.layout() }
        Debug.log("overlay shown on \(windows.count) screen(s), lock=\(onLockScreen)")
    }

    /// Droppy draws its own lock screen windows. If they live in a space that sits above ours, ours can be seen for a
    /// moment and then hidden whatever its window level. So join Droppy's space(s): there the level decides.
    private func shareDroppySpace() {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var spaces = Set<Int>()
        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            guard owner.contains("Droppy") || owner == "loginwindow", let id = w[kCGWindowNumber as String] as? Int else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let mine = LockSpace.spaces(of: id)
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            Debug.log("lockwin \(owner) layer=\(layer) onscreen=\(w[kCGWindowIsOnscreen as String] ?? false) \(b["Width"] ?? 0)x\(b["Height"] ?? 0) spaces=\(mine)")
            if owner == "loginwindow", w[kCGWindowIsOnscreen as String] as? Bool == true { spaces.formUnion(mine) }
        }
        let ours = windows.map { LockSpace.spaces(of: $0.windowNumber) }
        Debug.log("space levels: \(LockSpace.describeActiveSpace())")
        Debug.log("spaces: droppy lock windows in \(spaces.sorted()), ours in \(ours)")
        for window in windows { LockSpace.add(window, toSpaces: spaces.sorted()) }
        Debug.log("spaces after: ours in \(windows.map { LockSpace.spaces(of: $0.windowNumber) })")
    }

    private static func snapshot(_ window: NSWindow, name: String) {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            Debug.log("snapshot: CGWindowListCreateImage not available"); return
        }
        let capture = unsafeBitCast(pointer, to: Capture.self)
        guard let image = capture(.null, 8 /* this window only */, UInt32(window.windowNumber), 1)?.takeRetainedValue() else {
            Debug.log("snapshot \(name): no image"); return
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("albumscape-snap-\(name).png")
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        Debug.log("snapshot \(name): \(image.width)x\(image.height) -> \(url.lastPathComponent)")
    }

    /// Which windows Droppy and this app have, and on what layer: shows who is on top of whom on the lock screen.
    private static func logWindows() {
        // Every window on screen while locked, with its owner and layer: shows what draws the clock and the wallpaper.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = b["Width"] as? Double ?? 0, height = b["Height"] as? Double ?? 0
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard width >= 100 || height >= 100 || layer != 0 else { continue }
            let id = w[kCGWindowNumber as String] as? Int ?? 0
            Debug.log("onscreen \(owner) layer=\(layer) \(Int(width))x\(Int(height)) alpha=\(w[kCGWindowAlpha as String] ?? "?") id=\(id) spaces(7)=\(LockSpace.spaces(of: id)) ")
        }
    }

    private func cardFrame(on screen: NSScreen) -> NSRect {
        let frame = screen.frame, size = MiniPlayer.size
        return NSRect(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.235, width: size.width, height: size.height)
    }

    private func frostedCard() -> NSView {
        // Liquid Glass is the default on macOS 26: the system's own material (NSGlassEffectView), not a blur drawn by hand.
        // `defaults write com.adam.albumscape-lock nativeGlass -bool false` brings the old frosted card back.
        // The way Apple's Liquid Glass guide builds it: a SwiftUI view with .glassEffect(.regular) floating over the
        // content, in a clear window. `glassMode`: liquid (the default: the glass drawn here over the wallpaper), swiftui (macOS's
        // own glassEffect) or appkit (NSGlassEffectView), to compare the three.
        let mode = UserDefaults.standard.string(forKey: "glassMode") ?? "liquid"
        if mode == "liquid", let screen = screens.first, let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) {
            let card = cardFrame(on: screen)
            let origin = CGPoint(x: card.minX - screen.frame.minX, y: screen.frame.maxY - card.maxY)
            let started = Date()
            let glass = GlassShader.render(wallpaper: image, screenSize: screen.frame.size, origin: origin, size: MiniPlayer.size, scale: screen.backingScaleFactor)
            Debug.log("glass shader: \(glass == nil ? "failed" : "drawn") in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            let backdrop = GlassBackdrop(image: image, screenSize: screen.frame.size, origin: origin, glass: glass)
            return TapHostingView(rootView: MiniPlayer(model: model, nativeGlass: true, backdrop: backdrop))
        }
        if mode != "appkit", UserDefaults.standard.object(forKey: "nativeGlass") as? Bool != false, #available(macOS 26.0, *) {
            return TapHostingView(rootView: MiniPlayer(model: model, nativeGlass: false))
        }
        if UserDefaults.standard.object(forKey: "nativeGlass") as? Bool != false, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 30
            glass.contentView = TapHostingView(rootView: MiniPlayer(model: model, nativeGlass: true))
            return glass
        }
        // Droppy's own card is set to "frosted": a blurred, lightly tinted panel with a thin light edge.
        // `.active` keeps the blur on even though this window is never the key window.
        let frosted = NSVisualEffectView()
        frosted.material = .hudWindow
        frosted.blendingMode = .behindWindow
        frosted.state = .active
        frosted.appearance = NSAppearance(named: .vibrantDark)
        frosted.wantsLayer = true
        frosted.layer?.cornerRadius = 30
        frosted.layer?.cornerCurve = .continuous
        frosted.layer?.masksToBounds = true
        frosted.layer?.borderWidth = 0.8
        frosted.layer?.borderColor = NSColor.white.withAlphaComponent(0.32).cgColor
        let hosting = TapHostingView(rootView: MiniPlayer(model: model, nativeGlass: true))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        frosted.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: frosted.leadingAnchor), hosting.trailingAnchor.constraint(equalTo: frosted.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: frosted.topAnchor), hosting.bottomAnchor.constraint(equalTo: frosted.bottomAnchor)])
        return frosted
    }

    private func animateCorners(_ view: NSView?, from: CGFloat, to: CGFloat, duration: TimeInterval) {
        guard let layer = view?.layer else { return }
        layer.masksToBounds = true
        layer.cornerCurve = .continuous
        let animation = CABasicAnimation(keyPath: "cornerRadius")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "corners")
        layer.cornerRadius = to
    }

    /// Between full screen and the small card with quick cross-fades. Resizing the window frame by frame made the video
    /// stretch into the card's square and took most of half a second, so the window jumps to its new size while it is
    /// invisible and fades back in: about a third of a second in all.
    private func layout() {
        for (index, window) in windows.enumerated() where index < screens.count {
            let full = screens[index].frame, card = cardFrame(on: screens[index])
            let info = index < infoWindows.count ? infoWindows[index] : nil
            if model.expanded {
                // card -> full screen: the card fades out, the video fades in at full size, then the song info
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.1
                    window.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    guard let self, self.model.expanded else { return }
                    let host = TapHostingView(rootView: FullScreenView(model: self.model))
                    host.onBadgeClick = { [model = self.model] in model.toggleLyrics() }
                    host.onBackgroundClick = { [model = self.model] in if model.idleArt == nil { model.expanded = false } else { model.skipIdle() } }
                    window.isOpaque = true
                    window.backgroundColor = .black
                    window.contentView = host
                    window.setFrame(full, display: true)
                    window.alphaValue = 0
                    window.orderFrontRegardless()
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.2
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        window.animator().alphaValue = 1
                    }, completionHandler: {
                        guard let info, self.model.expanded else { return }
                        info.alphaValue = 0
                        info.setFrame(full, display: true)
                        info.orderFrontRegardless()
                        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; info.animator().alphaValue = 1 }
                    })
                })
            } else if index == 0 {
                // full screen -> card: the video and its info fade out, the card fades in where it belongs
                if let info { NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; info.animator().alphaValue = 0 }, completionHandler: { info.orderOut(nil) }) }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.15
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    window.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    guard let self, !self.model.expanded else { return }
                    window.isOpaque = false
                    window.backgroundColor = .clear
                    window.contentView = self.frostedCard()
                    window.setFrame(card, display: true)
                    window.alphaValue = 0
                    window.orderFrontRegardless()
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.18
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        window.animator().alphaValue = 1
                    }
                })
            } else {
                window.orderOut(nil)
                info?.orderOut(nil)
            }
        }
    }

    func raise() { windows.forEach { $0.orderFrontRegardless() } }

    func hide(keepPolling: Bool = false) {
        guard !windows.isEmpty else { return }
        windows.forEach { $0.orderOut(nil); $0.contentView = nil }
        windows.removeAll()
        infoWindows.forEach { $0.orderOut(nil); $0.contentView = nil }
        infoWindows.removeAll()
        modeWatch = nil
        _ = keepPolling  // the model keeps polling so lookups stay warm
        keepAwake(false)
        LockSpace.hide()
        Debug.log("overlay hidden")
    }
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    private let model = PlayerModel()
    private lazy var overlay = Overlay(model: model)
    private var item: NSStatusItem?
    private var enabled = true
    private var locked = false

    func applicationDidFinishLaunching(_ note: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--clock-test"), i + 1 < CommandLine.arguments.count {
            // The glass clock over the current wallpaper, into a PNG: `AlbumscapeLock --clock-test out.png`
            let screen = NSScreen.screens[0]
            let image = NSWorkspace.shared.desktopImageURL(for: screen).flatMap { NSImage(contentsOf: $0) }
            let path = CommandLine.arguments.count > i + 2 ? CommandLine.arguments[i + 2] : nil  // optional: another picture behind it
            let backdrop = path.flatMap { NSImage(contentsOfFile: $0) } ?? image
            if let glass = GlassText.render("9:41", fontSize: 124, backdrop: backdrop, screenSize: screen.frame.size, top: 85, scale: screen.backingScaleFactor),
               let back = backdrop, let behind = GlassShader.crop(back, screenSize: screen.frame.size, origin: CGPoint(x: (screen.frame.width - glass.size.width) / 2, y: 85), width: Int(glass.size.width * 2), height: Int(glass.size.height * 2), scale: 2) {
                let canvas = NSImage(size: glass.size)
                canvas.lockFocus()
                NSImage(cgImage: behind, size: glass.size).draw(in: NSRect(origin: .zero, size: glass.size))
                glass.draw(in: NSRect(origin: .zero, size: glass.size))
                canvas.unlockFocus()
                if let tiff = canvas.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                }
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--glass-test"), i + 1 < CommandLine.arguments.count {
            // Draws the card's glass over the current wallpaper into a PNG and quits: `AlbumscapeLock --glass-test out.png`
            let screen = NSScreen.screens[0]
            let card = NSRect(x: screen.frame.midX - MiniPlayer.size.width / 2, y: screen.frame.minY + screen.frame.height * 0.235, width: MiniPlayer.size.width, height: MiniPlayer.size.height)
            let origin = CGPoint(x: card.minX - screen.frame.minX, y: screen.frame.maxY - card.maxY)
            if let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url),
               let glass = GlassShader.render(wallpaper: image, screenSize: screen.frame.size, origin: origin, size: MiniPlayer.size, scale: screen.backingScaleFactor),
               let tiff = glass.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            }
            exit(0)
        }
        Debug.log("launched, skylight available: \(LockSpace.isAvailable)")
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didLock() }
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLockState() }  // macOS sends this about a second after locking too: verify it
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLockState() }
        }
        model.start()  // keeps the lookups warm, so the video is ready to go the moment the Mac locks
        // The desktop: the animated cover plays behind your icons while a song with one plays; the lock screen's wallpaper
        // is the still cover for a song with no animation (and your own wallpaper otherwise).
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.desktopTick() }
        }
        overlay.onDismiss = { [weak self] in
            Debug.log("overlay tapped: stepping aside")
            self?.dismissed = true
            self?.overlay.hide(keepPolling: true)
        }
        buildMenu()
        if CommandLine.arguments.contains("--preview") { preview() }
    }

    private var watch: AnyCancellable?
    private var pausedSince: Date?
    private var dismissed = false

    private var lockedAt = Date.distantPast

    /// What macOS itself says about the session: more reliable than the lock and unlock notifications, one of which
    /// arrives about a second after locking while the screen is still locked.
    private func sessionIsLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func checkLockState() {
        let now = sessionIsLocked()
        if !now && !locked { LockSpace.refreshBaseline() }
        if now && !locked { didLock() }
        else if !now && locked && Date().timeIntervalSince(lockedAt) > 3 { didUnlock() }  // the flag lags the notification
        if locked { follow() }  // the idle shuffle can start or end while the screen is locked
    }

    private var reasserter: Timer?

    private var wallpaperShown = ""  // "own", or the address of the cover on the wallpaper; empty until first set

    private func desktopTick() async {
        let animated = model.art?.motionURL
        if AnimatedWallpaper.enabled {
            let wall = AnimatedWallpaper.shared
            if let idle = model.idleArt?.motionURL {  // nothing playing: the shuffle
                if !locked, CGDisplayIsAsleep(CGMainDisplayID()) == 0 { wall.show(idle.absoluteString) } else { wall.pause() }
            } else if let animated {
                if model.track?.isPlaying == true, !locked, CGDisplayIsAsleep(CGMainDisplayID()) == 0 { wall.show(animated.absoluteString) } else { wall.pause() }
            } else {
                wall.hide()  // no animation for this song (or it is still being looked up): your own wallpaper shows
            }
        }
        guard Wallpaper.enabled else {
            // Not changing the wallpaper: but if an earlier version left a cover on it, put your own back, once.
            if wallpaperShown != "own" {
                wallpaperShown = "own"
                if let current = NSScreen.main.flatMap({ NSWorkspace.shared.desktopImageURL(for: $0) }), current.path.hasPrefix(Wallpaper.directory.path) { Wallpaper.restore() }
            }
            return
        }
        var wanted = "own"
        if locked, animated == nil, let cover = model.art?.coverURL { wanted = cover.absoluteString }
        guard wanted != wallpaperShown else { return }
        wallpaperShown = wanted
        if wanted == "own" { Wallpaper.restore() } else if let cover = URL(string: wanted) { await Wallpaper.set(cover: cover) }
    }

    private func didLock() {
        guard !locked else { return }
        reasserter?.invalidate()
        reasserter = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.locked, self.overlay.isShowing else { return }
                LockSpace.reassertShown()
                self.overlay.raise()
            }
        }
        Debug.log("screen locked (session flag: \(sessionIsLocked()))")
        dismissed = false
        lockedAt = Date()
        locked = true
        guard enabled else { return }
        model.start()  // polls while locked, so a song started after locking still shows
        watch = model.$track.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.follow() }
        follow()
    }

    private func didUnlock() {
        Debug.log("screen unlocked (session flag: \(sessionIsLocked()))")
        locked = false
        reasserter?.invalidate()
        reasserter = nil
        watch = nil
        pausedSince = nil
        overlay.hide()
    }

    /// While locked: show the video as soon as a song is playing; hide it a minute after the music stops, so the
    /// normal lock screen comes back when you're done listening.
    private func follow() {
        guard locked, enabled, !dismissed else { return }
        if model.track?.isPlaying == true || model.idleArt != nil {
            pausedSince = nil
            if !overlay.isShowing { overlay.show(onLockScreen: true) }
        } else if overlay.isShowing {
            let since = pausedSince ?? Date()
            pausedSince = since
            DispatchQueue.main.asyncAfter(deadline: .now() + 61) { [weak self] in
                guard let self, self.locked, self.pausedSince == since, self.model.track?.isPlaying != true, self.model.idleArt == nil else { return }
                self.overlay.hide(keepPolling: true)
                self.pausedSince = nil
            }
        }
    }

    private func preview() {
        overlay.show(onLockScreen: false)
        if CommandLine.arguments.contains("--mini") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.model.expanded = false } }
        DispatchQueue.main.asyncAfter(deadline: .now() + (CommandLine.arguments.contains("--hold") ? 150 : 20)) { [weak self] in
            self?.overlay.hide()
            if CommandLine.arguments.contains("--preview") { NSApp.terminate(nil) }
        }
    }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "music.note.tv", accessibilityDescription: "Albumscape Lock")
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Show on lock screen", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self; toggle.state = .on
        menu.addItem(toggle)
        let test = NSMenuItem(title: "Preview for 20 seconds", action: #selector(previewAction), keyEquivalent: "")
        test.target = self
        menu.addItem(test)
        let videos = NSMenuItem(title: "Music videos (off: animated covers only)", action: #selector(toggleVideos(_:)), keyEquivalent: "")
        videos.target = self
        videos.state = PlayerModel.videosAllowed ? .on : .off
        menu.addItem(videos)
        let skip = NSMenuItem(title: "Next animated cover", action: #selector(skipCover), keyEquivalent: "")
        skip.target = self
        menu.addItem(skip)
        let shuffle = NSMenuItem(title: "Shuffle animated covers when nothing plays", action: #selector(toggleShuffle(_:)), keyEquivalent: "")
        shuffle.target = self
        shuffle.state = PlayerModel.idleShuffleOn ? .on : .off
        menu.addItem(shuffle)
        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let id = NSMenuItem(title: "Spotify client ID…", action: #selector(setSpotifyClientID), keyEquivalent: "")
        id.target = self
        menu.addItem(id)
        let connect = NSMenuItem(title: "Connect Spotify…", action: #selector(connectSpotify), keyEquivalent: "")
        connect.target = self
        menu.addItem(connect)
        let disconnect = NSMenuItem(title: "Disconnect Spotify", action: #selector(disconnectSpotify), keyEquivalent: "")
        disconnect.target = self
        menu.addItem(disconnect)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        self.item = item
    }

    @objc private func setSpotifyClientID() {
        let alert = NSAlert()
        alert.messageText = "Spotify client ID"
        alert.informativeText = "Create a free app at developer.spotify.com/dashboard, add the redirect address \(SpotifyAccount.redirect), and paste its Client ID here."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = UserDefaults.standard.string(forKey: "spotifyClientID") ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            UserDefaults.standard.set(field.stringValue.trimmingCharacters(in: .whitespaces), forKey: "spotifyClientID")
        }
    }
    @objc private func connectSpotify() { SpotifyAccount.shared.connect() }
    @objc private func disconnectSpotify() { SpotifyAccount.shared.disconnect() }

    @objc private func skipCover() { model.skipIdle() }
    @objc private func toggleShuffle(_ sender: NSMenuItem) {
        let on = !PlayerModel.idleShuffleOn
        UserDefaults.standard.set(on, forKey: "idleShuffle")
        sender.state = on ? .on : .off
    }
    @objc private func toggleVideos(_ sender: NSMenuItem) {
        let on = !PlayerModel.videosAllowed
        UserDefaults.standard.set(on, forKey: "musicVideos")
        sender.state = on ? .on : .off
        model.videoSettingChanged()
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        enabled.toggle()
        sender.state = enabled ? .on : .off
        if !enabled { overlay.hide() }
    }

    @objc private func previewAction() { preview() }

    /// Off until you tick it: it shows up in System Settings, General, Login Items, where you can also remove it.
    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { Debug.log("login item: \(error)") }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = Delegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
