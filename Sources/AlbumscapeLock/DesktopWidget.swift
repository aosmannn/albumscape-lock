//
//  DesktopWidget.swift
//
//  A small now-playing card on the desktop, bottom-left: the cover, the song, a progress bar in the song's colour, and
//  the visualizer. It sits at the level of the desktop icons, under every app, and goes away when you lock the Mac or
//  nothing is playing. Settings > Desktop turns it off.
//

import AppKit
import SwiftUI

@MainActor
final class DesktopWidget {
    static let shared = DesktopWidget()
    static var enabled: Bool { UserDefaults.standard.object(forKey: "desktopWidget") as? Bool != false }
    private var window: NSWindow?

    func show(model: PlayerModel) {
        guard let screen = NSScreen.main else { return }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 330, height: 96), styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.isMovableByWindowBackground = true  // drag it where you like
            w.contentView = NSHostingView(rootView: WidgetView(model: model))
            let visible = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: visible.minX + 28, y: visible.minY + 28))
            w.alphaValue = 0
            window = w
        }
        guard let w = window else { return }
        if !w.isVisible { w.orderFront(nil) }
        if w.alphaValue < 1 { NSAnimationContext.runAnimationGroup { $0.duration = 0.35; w.animator().alphaValue = 1 } }
    }

    func hide() {
        guard let w = window, w.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; w.animator().alphaValue = 0 }, completionHandler: { w.orderOut(nil) })
    }
}

private struct WidgetView: View {
    @ObservedObject var model: PlayerModel
    private var accent: Color { model.art?.accent ?? .white }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let url = model.displayArt?.coverURL {
                    AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.white.opacity(0.1) }
                } else {
                    Color.white.opacity(0.1)
                }
            }
            .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.track?.title ?? "").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if AudioSpectrum.enabled { SpectrumBars(accent: accent, count: 5, barWidth: 3, spacing: 2.5).frame(width: 27, height: 12) }
                }
                Text(model.track?.artist ?? "").font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let position = model.position(at: context.date), duration = model.track?.duration ?? 0
                    Capsule().fill(.white.opacity(0.2)).frame(height: 3)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in Capsule().fill(accent).frame(width: geo.size.width * (duration > 0 ? min(1, max(0, position / duration)) : 0)) }
                        }
                }
                .frame(height: 3).padding(.top, 2)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 330, height: 96)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.black.opacity(0.42)))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
        .id(model.track?.key ?? "none")
        .animation(.easeInOut(duration: 0.4), value: model.track?.key)
    }
}
