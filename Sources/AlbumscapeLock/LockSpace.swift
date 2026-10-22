//
//  LockSpace.swift
//
//  Puts a window on the lock screen. macOS draws the lock screen in its own
//  window server space; apps like Droppy join it through SkyLight, a private
//  framework. Private API: it can change with any macOS update, so every
//  symbol is looked up at run time and the window just stays on the desktop
//  if one is missing.
//

import AppKit

enum LockSpace {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static var space: Int?

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    /// Whether the private calls are all there on this macOS.
    static var isAvailable: Bool {
        symbol("SLSMainConnectionID", as: (@convention(c) () -> Int32).self) != nil
            && symbol("SLSSpaceCreate", as: (@convention(c) (Int32, Int32, CFDictionary?) -> Int).self) != nil
            && symbol("SLSSpaceSetAbsoluteLevel", as: (@convention(c) (Int32, Int, Int32) -> Void).self) != nil
            && symbol("SLSShowSpaces", as: (@convention(c) (Int32, CFArray) -> Void).self) != nil
            && symbol("SLSAddWindowsToSpaces", as: (@convention(c) (Int32, CFArray, CFArray) -> Void).self) != nil
    }

    /// Moves `window` into a space that sits above the lock screen. Returns false if it couldn't.
    @discardableResult
    static func attach(_ window: NSWindow, level: Int32) -> Bool {
        guard let connection = symbol("SLSMainConnectionID", as: (@convention(c) () -> Int32).self),
              let create = symbol("SLSSpaceCreate", as: (@convention(c) (Int32, Int32, CFDictionary?) -> Int).self),
              let setLevel = symbol("SLSSpaceSetAbsoluteLevel", as: (@convention(c) (Int32, Int, Int32) -> Void).self),
              let show = symbol("SLSShowSpaces", as: (@convention(c) (Int32, CFArray) -> Void).self),
              let add = symbol("SLSAddWindowsToSpaces", as: (@convention(c) (Int32, CFArray, CFArray) -> Void).self)
        else { Debug.log("lock space: SkyLight symbols missing"); return false }

        let cid = connection()
        if space == nil {
            space = create(cid, 1, nil)
            setLevel(cid, space!, level)
        }
        show(cid, [NSNumber(value: Int32(space!))] as CFArray)  // every time: hide() turns it off after an unlock
        // What Droppy does: the window moves into this space and leaves the desktop's, which the lock screen hides.
        if let move = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: (@convention(c) (Int32, Int, CFArray, Int32) -> Void).self) {
            move(cid, space!, [NSNumber(value: Int32(window.windowNumber))] as CFArray, 7)
        } else {
            add(cid, [window.windowNumber] as CFArray, [space!] as CFArray)
        }
        Debug.log("lock space \(space!) level \(level) window \(window.windowNumber)")
        return true
    }

    /// The spaces a window is in (windows on the lock screen belong to spaces of their own).
    static func spaces(of windowID: Int) -> [Int] {
        guard let connection = symbol("SLSMainConnectionID", as: (@convention(c) () -> Int32).self),
              let copy = symbol("SLSCopySpacesForWindows", as: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?).self)
        else { return [] }
        return (copy(connection(), 7, [windowID] as CFArray)?.takeRetainedValue() as? [Int]) ?? []
    }

    /// Also puts `window` in these spaces, so it is ordered against the windows there by window level alone.
    static func add(_ window: NSWindow, toSpaces spaces: [Int]) {
        guard !spaces.isEmpty,
              let connection = symbol("SLSMainConnectionID", as: (@convention(c) () -> Int32).self),
              let add = symbol("SLSAddWindowsToSpaces", as: (@convention(c) (Int32, CFArray, CFArray) -> Void).self)
        else { return }
        add(connection(), [window.windowNumber] as CFArray, spaces as CFArray)
    }

    /// Shows our space again. The lock screen can switch visible spaces after its animation, taking ours with it.
    static func reassertShown() {
        guard let space,
              let connection = symbol("SLSMainConnectionID", as: (@convention(c) () -> Int32).self),
              let show = symbol("SLSShowSpaces", as: (@convention(c) (Int32, CFArray) -> Void).self) else { return }
        show(connection(), [NSNumber(value: Int32(space))] as CFArray)
    }

    /// Hides our space again once the screen is unlocked.
    static func hide() {
        guard let space,
              let connection = symbol("SLSMainConnectionID", as: (@convention(c) () -> Int32).self),
              let hide = symbol("SLSHideSpaces", as: (@convention(c) (Int32, CFArray) -> Void).self) else { return }
        hide(connection(), [NSNumber(value: Int32(space))] as CFArray)
    }

    /// For the log: which space is active and its level, to place ours relative to the lock screen's own UI.
    static func describeActiveSpace() -> String {
        guard let connection = symbol("SLSMainConnectionID", as: (@convention(c) () -> Int32).self),
              let active = symbol("SLSGetActiveSpace", as: (@convention(c) (Int32) -> Int).self),
              let level = symbol("SLSSpaceGetAbsoluteLevel", as: (@convention(c) (Int32, Int) -> Int32).self)
        else { return "unavailable" }
        let cid = connection(), id = active(cid)
        let ours = space.map { "ours \($0) level \(level(cid, $0))" } ?? "ours none"
        return "active space \(id) level \(level(cid, id)), \(ours)"
    }

    /// Puts `window` into the space macOS is showing right now (the lock screen's own), so it is ordered against the
    /// lock UI by window level: a level below loginwindow's (2001, 2004) plays behind the clock and login, above the
    /// wallpaper. Returns false if the calls aren't there.
    @discardableResult
    static func attachToActiveSpace(_ window: NSWindow) -> Bool {
        guard let connection = symbol("SLSMainConnectionID", as: (@convention(c) () -> Int32).self),
              let active = symbol("SLSGetActiveSpace", as: (@convention(c) (Int32) -> Int).self),
              let move = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: (@convention(c) (Int32, Int, CFArray, Int32) -> Void).self)
        else { Debug.log("active space: symbols missing"); return false }
        let cid = connection(), id = active(cid)
        move(cid, id, [NSNumber(value: Int32(window.windowNumber))] as CFArray, 7)
        Debug.log("window \(window.windowNumber) moved into active space \(id)")
        return true
    }

    /// Every space id with a non-zero level, to find where the lock screen's own UI sits.
    static func otherLevels() -> [(id: Int, level: Int32)] {
        guard let connection = symbol("SLSMainConnectionID", as: (@convention(c) () -> Int32).self),
              let level = symbol("SLSSpaceGetAbsoluteLevel", as: (@convention(c) (Int32, Int) -> Int32).self) else { return [] }
        let cid = connection()
        return (1...800).compactMap { id in
            let l = level(cid, id)
            return (l != 0 && id != space) ? (id, l) : nil
        }
    }

    /// Puts our space at `newLevel`.
    static func setLevel(_ newLevel: Int32) {
        guard let space,
              let connection = symbol("SLSMainConnectionID", as: (@convention(c) () -> Int32).self),
              let set = symbol("SLSSpaceSetAbsoluteLevel", as: (@convention(c) (Int32, Int, Int32) -> Void).self) else { return }
        set(connection(), space, newLevel)
    }

    /// Spaces that exist while the Mac is unlocked. At lock time the lock screen creates its own; whatever is new
    /// then (and not ours) is where its wallpaper and clock live.
    static var baseline: Set<Int> = []

    static func refreshBaseline() { baseline = Set(otherLevels().map(\.id)) }

    /// The space(s) that appeared when the screen locked, other than ours.
    static func newSpaces() -> [(id: Int, level: Int32)] { otherLevels().filter { !baseline.contains($0.id) } }

    /// Moves `window` into the given space, which removes it from ours.
    static func move(_ window: NSWindow, toSpace id: Int) {
        guard let connection = symbol("SLSMainConnectionID", as: (@convention(c) () -> Int32).self),
              let move = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: (@convention(c) (Int32, Int, CFArray, Int32) -> Void).self)
        else { return }
        move(connection(), id, [NSNumber(value: Int32(window.windowNumber))] as CFArray, 7)
    }
}
