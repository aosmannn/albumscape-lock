//
//  Wallpaper.swift
//
//  Sets the desktop picture to the cover of the song playing, scaled to fill each screen and cropped from the centre.
//  `defaults write com.adam.albumscape-lock coverWallpaper -bool false` turns it off.
//

import AppKit
import CryptoKit

enum Wallpaper {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AlbumscapeLock/wallpapers", isDirectory: true)
    }()
    private static var originalFile: URL { directory.appendingPathComponent("original-wallpaper.txt") }

    /// Off unless asked for: `defaults write com.adam.albumscape-lock coverWallpaper -bool true` puts the still cover on
    /// the lock screen's wallpaper for songs with no animation. By default your own wallpaper is never touched.
    static var enabled: Bool {
        let suite = UserDefaults(suiteName: "com.adam.albumscape-lock")?.object(forKey: "coverWallpaper") as? Bool
        return (suite ?? UserDefaults.standard.object(forKey: "coverWallpaper") as? Bool) == true
    }

    /// Puts `cover` on every screen. The picture is made once per cover and screen shape, then reused.
    @MainActor
    static func set(cover: URL) async {
        guard enabled else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        seedOriginalFromHelper()
        // Remember what the wallpaper was, once, so it can be put back.
        if !FileManager.default.fileExists(atPath: originalFile.path), let current = NSScreen.main.flatMap({ NSWorkspace.shared.desktopImageURL(for: $0) }), !current.path.hasPrefix(directory.path) {
            try? current.path.write(to: originalFile, atomically: true, encoding: .utf8)
        }
        var downloaded: NSImage?
        for screen in NSScreen.screens {
            let scale = screen.backingScaleFactor
            let w = Int(screen.frame.width * scale), h = Int(screen.frame.height * scale)
            let name = SHA256.hash(data: Data("\(cover.absoluteString)|\(w)x\(h)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            let file = directory.appendingPathComponent("\(name).jpg")
            if !FileManager.default.fileExists(atPath: file.path) {
                if downloaded == nil {
                    guard let (data, _) = try? await URLSession.shared.data(from: cover), let image = NSImage(data: data) else { return }
                    downloaded = image
                }
                guard let image = downloaded, let jpeg = fill(image, width: w, height: h) else { continue }
                try? jpeg.write(to: file)
            }
            if NSWorkspace.shared.desktopImageURL(for: screen) == file { continue }
            try? NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true])
        }
        prune()
        Debug.log("wallpaper: set to the cover of the song playing (lock screen)")
    }

    /// The helper app this one replaced had already saved what your wallpaper was: keep that, not a cover it had set.
    private static func seedOriginalFromHelper() {
        let old = directory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DroppyMotionFill/wallpapers/original-wallpaper.txt")
        if !FileManager.default.fileExists(atPath: originalFile.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.copyItem(at: old, to: originalFile)
        }
    }

    /// Back to the wallpaper from before the first change.
    @MainActor
    static func restore() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        seedOriginalFromHelper()
        Debug.log("wallpaper: back to your own")
        guard let path = try? String(contentsOf: originalFile, encoding: .utf8) else { return }
        for screen in NSScreen.screens { try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:]) }
    }

    private static func fill(_ image: NSImage, width: Int, height: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let scale = max(CGFloat(width) / image.size.width, CGFloat(height) / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: (CGFloat(width) - drawn.width) / 2, y: (CGFloat(height) - drawn.height) / 2, width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    /// Keeps the folder small: the 40 newest pictures.
    private static func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let pictures = files.filter { $0.pathExtension == "jpg" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for old in pictures.dropFirst(40) { try? FileManager.default.removeItem(at: old) }
    }
}
