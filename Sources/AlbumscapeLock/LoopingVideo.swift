//
//  LoopingVideo.swift
//  Albumscape
//

import AVFoundation
import AppKit
import SwiftUI

/// A muted, looping, edge-to-edge video: motion album art or a music video.
/// `onReady` fires once a frame is on screen, `onFailure` if the stream can't play,
/// so the caller can show something else instead of a blank square.
struct LoopingVideo: NSViewRepresentable {
    let url: URL
    var onReady: () -> Void = {}
    var onFailure: () -> Void = {}

    func makeNSView(context: Context) -> PlayerView { PlayerView() }

    func updateNSView(_ view: PlayerView, context: Context) {
        view.onReady = onReady
        view.onFailure = onFailure
        view.play(url)
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) { view.stop() }

    final class PlayerView: NSView {
        var onReady: () -> Void = {}
        var onFailure: () -> Void = {}

        private let player = AVPlayer()
        private let playerLayer: AVPlayerLayer
        private var current: URL?
        private var observers: [NSKeyValueObservation] = []
        private var endObserver: NSObjectProtocol?
        private var tick: Any?

        override init(frame: NSRect) {
            playerLayer = AVPlayerLayer(player: player)
            super.init(frame: frame)
            wantsLayer = true
            layer = playerLayer
            playerLayer.videoGravity = .resizeAspectFill
            player.isMuted = true
            player.actionAtItemEnd = .none
            observers.append(playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                if layer.isReadyForDisplay { DispatchQueue.main.async { self?.onReady() } }
            })
        }

        required init?(coder: NSCoder) { fatalError() }

        func play(_ url: URL) {
            guard url != current else { return }
            current = url
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            let item = AVPlayerItem(url: url)
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                self?.player.seek(to: .zero)  // a plain seek loops HLS reliably; AVPlayerLooper does not
                self?.player.play()
            }
            observers.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .failed { DispatchQueue.main.async { self?.onFailure() } }
            })
            player.replaceCurrentItem(with: item)
            // carry on from where the other player (the desktop's) has this video, if it has
            if let start = PlaybackClock.shared.position(of: url) {
                observers.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .readyToPlay else { return }
                    DispatchQueue.main.async { self?.player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) }
                })
            }
            player.play()
            if let tick { player.removeTimeObserver(tick) }
            tick = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
                guard let self, let item = self.player.currentItem else { return }
                MainActor.assumeIsolated { PlaybackClock.shared.note(url, time: time.seconds, duration: item.duration.seconds) }
            }
        }

        func stop() {
            player.pause()
            player.replaceCurrentItem(with: nil)
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
            observers.removeAll()
        }
    }
}
