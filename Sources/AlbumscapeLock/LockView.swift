//
//  LockView.swift
//

import SwiftUI

/// Two states, like Droppy's lock screen player: the song's video (else its motion art, else its cover) full screen
/// with the song info on it, and, after a click, a small player card with the cover, the song and the controls,
/// leaving macOS's own lock screen visible around it.
struct LockView: View {
    @ObservedObject var model: PlayerModel
    static var useNativeGlass: Bool { if #available(macOS 26.0, *) { return true } else { return false } }

    var body: some View {
        if model.expanded { FullScreenView(model: model) } else { MiniPlayer(model: model, nativeGlass: LockView.useNativeGlass) }
    }
}

// MARK: - Full screen

/// The song info and its shade, drawn in a window of its own above the video's: a native video view always paints
/// over SwiftUI siblings, which hid this text as soon as the video started.
struct InfoOverlayView: View {
    @ObservedObject var model: PlayerModel
    private var accent: Color { model.art?.accent ?? .white }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.clear, .black.opacity(model.lyricsOn && !model.lyrics.isEmpty ? 0.85 : 0.7)], startPoint: .center, endPoint: .bottom)
            if model.lyricsOn, !model.lyrics.isEmpty { LyricsView(model: model, accent: accent) }
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                SongInfo(track: model.idleArt == nil ? model.track : nil, position: model.position(at: context.date), accent: accent, album: model.art?.album).padding(48)
            }
            .id(model.track?.key ?? "none")
            .transition(.opacity)
            LockClock(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 70)
            if model.idleArt == nil {  // the shuffle shows only the animation and the clock
                LyricsBadge(on: model.lyricsOn, hasLyrics: !model.lyrics.isEmpty, accent: accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.leading, 32).padding(.top, 60)
            }
            if let toast = model.toast {
                Text(toast).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8).background(Capsule().fill(.black.opacity(0.55)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 60)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: model.track?.key)
        .allowsHitTesting(false)
    }
}

/// The date and time at the top, the way the Mac's own lock screen shows them: the full-screen video covers that one.
/// The numbers are drawn as glass: a see-through white that is brighter at the top, with a light rim on the top edge, a
/// soft sheen across the upper half and a shadow beneath. When the minute changes, the digits roll over into the new ones.
struct LockClock: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let time = UserDefaults.standard.bool(forKey: "clock24h")
                ? context.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
                : context.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale.current))
                    .replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: "")
                    .replacingOccurrences(of: "\u{202F}AM", with: "").replacingOccurrences(of: "\u{202F}PM", with: "")
            VStack(spacing: 0) {
                Text(context.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 1)
                glassTime(time).padding(.top, -10)
            }
        }
    }

    /// The time as clear glass over whatever is behind it (video, animation or cover): the picture shows through the
    /// digits untouched, and the glass only adds light (Shaders/Liquid.metal: glassShine) and a little edge shade
    /// (liquidShade). Still; the digits roll over when the minute changes.
    private func glassTime(_ time: String) -> some View {
        let digits = Text(time)
            .font(.system(size: 124, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .contentTransition(.numericText())
            .animation(.smooth(duration: 0.7), value: time)
            .padding(8)
        return ZStack {
            digits.layerEffect(ShaderLibrary.liquidShade(.float(0)), maxSampleOffset: CGSize(width: 3, height: 3))
            // plain see-through drawing: the clock sits in its own window over the video's, where blend modes can't reach
            digits.layerEffect(ShaderLibrary.glassShine(), maxSampleOffset: CGSize(width: 3, height: 3))
        }
    }
}

/// The small L badge, like Droppy's: lit when lyrics are on. Drawn here (this window ignores clicks); the click is caught
/// by the video window under it, in the top-left corner (see FullScreenView).
struct LyricsBadge: View {
    static let hitSize = CGSize(width: 130, height: 150)
    let on: Bool
    let hasLyrics: Bool
    let accent: Color

    var body: some View {
        Text("L").font(.system(size: 14, weight: .heavy, design: .rounded))
            .foregroundStyle(on ? Color.black.opacity(0.85) : Color.white.opacity(0.9))
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? accent : Color.black.opacity(0.4)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.35), lineWidth: 1))
            .opacity(hasLyrics ? 1 : 0.55)
            .shadow(color: .black.opacity(0.4), radius: 6)
    }
}

/// The current line in white, the next one dim below, at a medium size. LRCLIB times whole lines, not
/// words, so inside a line the words fill in one after another across the time it takes to sing it, which moves
/// the way Apple Music's lyrics do.
struct LyricsView: View {
    @ObservedObject var model: PlayerModel
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = model.position(at: context.date)
            let lines = model.lyrics
            let index = lines.lastIndex { $0.time <= t + 0.25 } ?? -1
            VStack(spacing: 10) {
                Group {
                    if index >= 0 { Text(sung(lines, index, at: t)) } else { Text("") }
                }
                .font(.system(size: 34, weight: .bold))
                .id(index)
                .transition(.opacity.combined(with: .offset(y: -10)))
                Text(index + 1 < lines.count ? lines[index + 1].text : "")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).opacity(0.5)
            }
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 220)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: -10)
            .animation(.easeOut(duration: 0.25), value: index)
            .opacity(model.track?.isPlaying == true ? 1 : 0)
            .shadow(color: .black.opacity(0.7), radius: 14, y: 2)
        }
    }

    /// The line with each word lit by how far through it the singer is.
    private func sung(_ lines: [LyricLine], _ index: Int, at t: TimeInterval) -> AttributedString {
        let line = lines[index]
        let text = line.text.isEmpty ? "♪" : line.text
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let next = index + 1 < lines.count ? lines[index + 1].time : line.time + 6
        // Singing usually ends before the next line starts: allow about 0.4 s a word, never longer than the gap.
        let span = max(0.8, min(next - line.time - 0.15, Double(words.count) * 0.4 + 0.6))
        let progress = min(1, max(0, (t - line.time) / span))
        let weights = words.map { Double($0.count + 2) }
        let total = weights.reduce(0, +)
        var result = AttributedString()
        var before = 0.0
        for (i, word) in words.enumerated() {
            let share = (progress * total - before) / weights[i]  // 0 = not reached, 1 = fully sung
            let lit = min(1, max(0, share))
            before += weights[i]
            var piece = AttributedString(word + (i < words.count - 1 ? " " : ""))
            piece.foregroundColor = Color.white.opacity(0.42 + 0.58 * lit)
            result += piece
        }
        return result
    }
}

struct FullScreenView: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        ZStack {
            Color.black
            MediaLayer(model: model)
        }
        .ignoresSafeArea()
        .clipped()
        .contentShape(Rectangle())
    }
}

/// The picture for the song, full screen or in the small square: the cover first, and over it the music video if
/// there is one, else Apple Music's motion art, else Apple's clip. A source that fails hands over to the next.
struct MediaLayer: View {
    @ObservedObject var model: PlayerModel
    /// Set for the small square: YouTube won't draw in a box under about 200 points, so the player is laid out at
    /// that size and shrunk to fit.
    var thumbnailSide: CGFloat?
    @State private var failed: Set<String> = []
    /// Each source reports when it has a first frame; the first one (in order) that has is shown. The one that was on
    /// screen stays underneath until the next is ready and has faded in, so skipping to another cover never goes black.
    @State private var readyKeys: Set<String> = []
    @State private var hold: Source?
    @State private var fading: Source?
    @State private var leaving: Source?  // the last song's picture, fading out as the new song's comes in
    @State private var coverFront: NSImage?
    @State private var coverBack: NSImage?
    @State private var frontOpacity = 1.0

    private enum Source: Equatable {
        case youtube(YouTubeVideo), file(URL)
        var key: String {
            switch self { case .youtube(let v): return "yt:\(v.id)"; case .file(let u): return u.absoluteString }
        }
    }

    private var sources: [Source] {
        // In the small square YouTube's own buttons and titles would show (and its pause symbol while paused), so there
        // the video only plays while the song does, and is zoomed in so its edges, where those sit, fall outside.
        let showVideo = thumbnailSide == nil || model.track?.isPlaying == true
        let videos = PlayerModel.videosAllowed  // off: only the animated cover or the still cover
        let youtube = showVideo && videos && model.idleArt == nil ? model.video.map(Source.youtube) : nil
        let motion = model.displayArt?.motionURL.map(Source.file)
        let clip = videos && model.idleArt == nil ? model.art?.videoURL.map(Source.file) : nil
        // "If no animation": the animated cover comes first, so a video only shows for albums without one
        return (PlayerModel.videoMode == "noMotion" ? [motion, youtube, clip] : [youtube, motion, clip])
            .compactMap { $0 }.filter { !failed.contains($0.key) }
    }

    private var shownKey: String? { sources.first { readyKeys.contains($0.key) }?.key }

    /// What is drawn: the current sources, plus the previous picture while it is still needed underneath.
    private var rendered: [Source] {
        var list: [Source] = []
        for old in [fading, hold, leaving] {
            if let old, !sources.contains(old), !list.contains(old) { list.append(old) }
        }
        return list + sources
    }

    private func visible(_ source: Source) -> Bool {
        if isYouTube(source), model.track?.isPlaying != true { return false }  // YouTube's own pause symbol never shows
        if source.key == shownKey { return true }
        if shownKey == nil, source == hold, model.idleArt != nil { return true }  // shuffling: the old cover stays until the next is ready (a song change shows its own cover at once)
        return source == fading
    }

    var body: some View {
        ZStack {
            // The covers: the new one fades in over the old one, which is then dropped.
            if let back = coverBack {
                Image(nsImage: back).resizable().aspectRatio(contentMode: .fill).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            }
            if let front = coverFront {
                Image(nsImage: front).resizable().aspectRatio(contentMode: .fill).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .opacity(frontOpacity)
            }
            ForEach(rendered, id: \.key) { source in
                player(source)
                    .opacity(visible(source) ? 1 : 0)
                    .animation(.easeInOut(duration: 0.6), value: visible(source))
            }
        }
        .clipped()
        .task(id: model.displayArt?.coverURL) {
            guard let url = model.displayArt?.coverURL, let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data), !Task.isCancelled else { return }
            coverBack = coverFront
            coverFront = image
            frontOpacity = coverBack == nil ? 0 : 0.0
            withAnimation(.easeInOut(duration: 0.7)) { frontOpacity = 1 }
            try? await Task.sleep(for: .seconds(0.8))
            if !Task.isCancelled { coverBack = nil }
        }
        .onChange(of: model.track?.key) { _ in
            // a new song: the last song's video fades out while its cover is replaced
            if let h = hold { leaving = h; DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if leaving == h { leaving = nil } } }
            if model.idleArt == nil { hold = nil }
        }
        .onChange(of: shownKey) { newKey in
            guard let newKey, let new = sources.first(where: { $0.key == newKey }) else { return }
            if let old = hold, old.key != newKey {
                fading = old
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if fading == old { fading = nil } }
            }
            hold = new
        }
        .onChange(of: rendered.map(\.key)) { keys in readyKeys = readyKeys.intersection(keys) }
    }

    private func isYouTube(_ source: Source) -> Bool { if case .youtube = source { return true } else { return false } }

    @ViewBuilder private func player(_ source: Source) -> some View {
        switch source {
        case .youtube(let v):
            let embed = YouTubeEmbed(video: v, startAt: model.track?.position ?? 0,
                                     playing: model.track?.isPlaying == true,
                                     position: { [model] in model.position(at: Date()) + v.offset },
                                     songRemaining: { [model] in max(0, (model.track?.duration ?? 0) - model.position(at: Date())) },
                                     onReady: { Debug.log("yt ready"); readyKeys.insert(source.key) },
                                     onFailure: { Debug.log("yt FAILED"); failed.insert(source.key) },
                                     onHide: { readyKeys.remove(source.key) })
            if let side = thumbnailSide {
                let layout: CGFloat = 320
                embed.frame(width: layout, height: layout).scaleEffect(side / layout * 1.75).frame(width: side, height: side).clipped()
            } else {
                embed
            }
        case .file(let url):
            LoopingVideo(url: url,
                         onReady: { Debug.log("file ready"); readyKeys.insert(source.key) },
                         onFailure: { Debug.log("file FAILED"); failed.insert(source.key) })
        }
    }
}

/// Title, artist and album, with the progress bar and times: the song info Albumscape shows on the video.
private struct SongInfo: View {
    let track: Track?
    let position: TimeInterval
    let accent: Color
    let album: String?

    var body: some View {
        if let track {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 12) {
                    Text(track.title).font(.system(size: 36, weight: .bold)).lineLimit(1)
                    // small and level with the title's middle, like the one in Droppy's widget
                    if AudioSpectrum.enabled {  // paused it stays, as still dots, and starts moving the moment sound does
                        SpectrumBars(accent: accent, count: 5, barWidth: 3.5, spacing: 3).frame(width: 29.5, height: 20)
                    }
                }
                Text([track.artist, album ?? track.album].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(.system(size: 18)).opacity(0.8).lineLimit(1)
                if track.duration > 0 {
                    HStack(spacing: 12) {
                        Text(timeString(position)).foregroundStyle(accent)
                        ProgressView(value: min(position, track.duration), total: track.duration)
                            .tint(accent).frame(maxWidth: 420)
                        Text("-" + timeString(max(0, track.duration - position))).foregroundStyle(accent)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .monospaced)).padding(.top, 6)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 12)
        }
    }
}

private func timeString(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Mini player

/// Laid out from a photo of Droppy's own lock screen player: a Liquid Glass card with the cover and the song on top,
/// one row of elapsed time, progress bar and time left, then heart, back, play/pause, forward and the output icon.
/// The cover moves when the album has motion art. Click it to open the full screen video again.
struct MiniPlayer: View {
    @ObservedObject var model: PlayerModel
    /// True when the window itself is an NSGlassEffectView, so the card must not draw a background of its own.
    var nativeGlass = false
    /// The picture behind the card (the wallpaper), when we draw the glass ourselves.
    var backdrop: GlassBackdrop?
    @State private var showOutputs = UserDefaults.standard.bool(forKey: "debugOutputsOpen")  // only the layout test sets this
    @State private var outputs: [OutputDevice] = []
    @State private var scrub: Double?  // while the progress bar is being dragged: where, 0 to 1

    static let size = CGSize(width: 410, height: 160)
    /// How much taller the card gets for its output list: a divider, a heading and a row per device (at most three).
    static func outputsExtra(_ devices: Int) -> CGFloat { 38 + CGFloat(min(max(devices, 1), 3)) * 54 }

    private var playerContent: some View {
        VStack(spacing: 10) {
            HStack(spacing: 11) {
                MediaLayer(model: model, thumbnailSide: 54)
                    .background(Color.white.opacity(0.12))
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { model.expanded = true }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.track?.title ?? "Nothing playing").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Button { model.toggleLyrics() } label: {
                            Text("L").font(.system(size: 11, weight: .heavy, design: .rounded))
                                .foregroundStyle(.black.opacity(0.88))
                                .frame(width: 18, height: 18)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(model.lyricsOn ? 0.95 : 0.55)))
                        }.buttonStyle(.plain).opacity(model.lyrics.isEmpty ? 0.6 : 1)
                    }
                    Text(model.track?.artist ?? "").font(.system(size: 12.5)).opacity(0.8).lineLimit(1)
                }
                .id(model.track?.key ?? "none").transition(.opacity)  // the title and artist fade into the next song's
                .animation(.easeInOut(duration: 0.4), value: model.track?.key)
                Spacer(minLength: 0)
                if AudioSpectrum.enabled { SpectrumBars(accent: accent, count: 5, barWidth: 3, spacing: 2.5).frame(width: 25, height: 14) }
            }

            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                let position = model.position(at: context.date)
                let duration = model.track?.duration ?? 0
                HStack(spacing: 10) {
                    Text(timeString(scrub.map { $0 * duration } ?? position)).frame(width: 34, alignment: .leading)
                    GeometryReader { geo in
                        let shown = scrub ?? (duration > 0 ? min(1, max(0, position / duration)) : 0)
                        let thick: CGFloat = scrub == nil ? 4 : 8
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.28)).frame(height: thick)
                            Capsule().fill(accent).frame(width: max(thick, geo.size.width * shown), height: thick)
                        }
                        .frame(height: geo.size.height)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { g in if duration > 0 { scrub = min(1, max(0, g.location.x / geo.size.width)) } }
                            .onEnded { g in
                                if duration > 0 { model.seek(to: min(1, max(0, g.location.x / geo.size.width)) * duration) }
                                scrub = nil
                            })
                        .animation(.easeOut(duration: 0.12), value: scrub == nil)
                    }
                    .frame(height: 22)
                    Text("-" + timeString(max(0, duration - position)))
                        .frame(width: 38, alignment: .trailing)
                }
            }
            .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(accent)

            ZStack {
                HStack(spacing: 38) {
                    SkipButton(symbol: "backward.fill", forward: false, action: model.previous)
                    control(model.track?.isPlaying == true ? "pause.fill" : "play.fill", 28, model.playPause)
                    SkipButton(symbol: "forward.fill", forward: true, action: model.next)
                }
                HStack {
                    Button { model.toggleLike() } label: {
                        Image(systemName: model.liked ? "heart.fill" : "heart").font(.system(size: 16))
                            .foregroundStyle(model.liked ? accent : .white).opacity(model.liked ? 1 : 0.85)
                    }.buttonStyle(.plain)
                    Spacer()
                    Button {
                        outputs = AudioOutputs.list()
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { showOutputs.toggle() }
                        model.outputsHeight = showOutputs ? Self.outputsExtra(outputs.count) : 0  // tells a glass window that holds this view to grow too
                    } label: {
                        Image(systemName: "airplayaudio").font(.system(size: 16)).opacity(showOutputs ? 1 : 0.85)
                            .frame(width: 46, height: 46)
                            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(.white.opacity(showOutputs ? 0.16 : 0)))
                            .contentShape(Rectangle())
                    }.buttonStyle(PressStyle())
                }
            }
            .frame(height: 30)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        .padding(.horizontal, 14).padding(.vertical, 13)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    /// The window is as tall as the card can ever be, clear below the card, so opening the list is only the card's own
    /// height animating (the glass stretches with a spring); the window itself never has to be resized.
    static var maxExtra: CGFloat { outputsExtra(3) }

    var body: some View {
        let extra = showOutputs ? Self.outputsExtra(outputs.count) : 0
        let cardSize = CGSize(width: Self.size.width, height: Self.size.height + extra)
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                playerContent
                outputsList
                    .frame(width: Self.size.width, height: Self.outputsExtra(outputs.count), alignment: .top)
                    .opacity(showOutputs ? 1 : 0)
                    .animation(.easeOut(duration: showOutputs ? 0.3 : 0.12).delay(showOutputs ? 0.12 : 0), value: showOutputs)
            }
            .frame(width: cardSize.width, height: cardSize.height, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .modifier(GlassBackground(enabled: nativeGlass == false))
            .background { if let backdrop { LiquidGlassCard(backdrop: backdrop, size: cardSize) } }
            .overlay(alignment: .top) {
                if let toast = model.toast {
                    Text(toast).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(.black.opacity(0.6)))
                        .padding(.top, 6).transition(.opacity)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height + Self.maxExtra, alignment: .top)
        .onAppear { if showOutputs && outputs.isEmpty { outputs = AudioOutputs.list() } }
    }

    private var accent: Color { model.art?.accent ?? .white }

    /// The area that opens under the controls, like Droppy's: a heading, then each speaker or headphone with a check on
    /// the one in use; on that row the lighter fill is the volume, and dragging along it changes it.
    private var outputsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.horizontal, 20)
            Text("Outputs").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 28).padding(.top, 4)
            ForEach(outputs.prefix(3)) { device in
                OutputRow(device: device, accent: accent) { chosen in
                    if AudioOutputs.select(chosen.id) { outputs = AudioOutputs.list() }
                } setVolume: { v in
                    AudioOutputs.setVolume(v, of: device.id)
                    if let i = outputs.firstIndex(where: { $0.id == device.id }) { outputs[i].volume = v }
                }
            }
        }
        .padding(.bottom, 12)
    }

    private var progress: Double {
        guard let t = model.track, t.duration > 0 else { return 0 }
        return min(1, max(0, t.position / t.duration))
    }

    private func control(_ symbol: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 36).contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }
}

/// Next and back: the arrows ripple, shoot off in their direction and come back in from the other side, so a press feels
/// like winding forward or rewinding.
private struct SkipButton: View {
    let symbol: String
    let forward: Bool
    let action: () -> Void
    @State private var tick = 0
    @State private var slide: CGFloat = 0
    @State private var fade = 1.0

    var body: some View {
        Button {
            action()
            tick += 1
            let d: CGFloat = forward ? 1 : -1
            withAnimation(.easeIn(duration: 0.12)) { slide = 18 * d; fade = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                slide = -18 * d  // jumps to the other side while invisible
                withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) { slide = 0; fade = 1 }
            }
        } label: {
            Image(systemName: symbol).font(.system(size: 22, weight: .bold))
                .symbolEffect(.bounce.byLayer, options: .nonRepeating, value: tick)
                .offset(x: slide).opacity(fade)
                .frame(width: 44, height: 36).contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }
}

private struct GlassBackground: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            // Apple's recipe: the glass sits in a GlassEffectContainer, so it can stretch and blend as one surface
            if #available(macOS 26.0, *) { GlassEffectContainer { content.liquidGlass(cornerRadius: 30) } } else { content.liquidGlass(cornerRadius: 30) }
        } else { content }
    }
}

extension View {
    /// macOS 26's Liquid Glass, as Droppy uses; a blurred material before that.
    @ViewBuilder func liquidGlass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

/// A quick squash on press, so a tap is felt before the player has answered.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.82 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Liquid Glass, drawn here

struct GlassBackdrop {
    let image: NSImage
    let screenSize: CGSize
    let origin: CGPoint  // the card's top-left corner on the screen
}

/// Our Liquid Glass (Shaders/Liquid.metal, glassLens): the wallpaper behind the card, lightly softened, magnified like a
/// thick slab of glass and bent strongly at its curved rim, with thin bright edges. It doesn't follow the pointer.
struct LiquidGlassCard: View {
    let backdrop: GlassBackdrop
    let size: CGSize
    private let radius: CGFloat = 40

    var body: some View {
        Image(nsImage: backdrop.image).resizable().scaledToFill()
            .frame(width: backdrop.screenSize.width, height: backdrop.screenSize.height).clipped()
            .blur(radius: 2)
            .saturation(1.2)
            .offset(x: -backdrop.origin.x, y: -backdrop.origin.y)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .layerEffect(ShaderLibrary.glassLens(.float2(size), .float(radius), .float2(0.2, -0.1), .float(0)),
                         maxSampleOffset: CGSize(width: 60, height: 60))
            .frame(width: size.width, height: size.height)
    }
}

/// One output in the list: the device's icon and name, a check (or an empty dot) on the right, and, on the one in use, a
/// lighter fill that is its volume.
private struct OutputRow: View {
    let device: OutputDevice
    let accent: Color
    let choose: (OutputDevice) -> Void
    let setVolume: (Float) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10))
                if device.isCurrent, let volume = device.volume {
                    Capsule().fill(.white.opacity(0.22)).frame(width: max(44, geo.size.width * CGFloat(volume)))
                }
                HStack(spacing: 12) {
                    Image(systemName: device.symbol).font(.system(size: 15)).frame(width: 24)
                    Text(device.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: device.isCurrent ? "checkmark.circle.fill" : "circle.fill")
                        .font(.system(size: 22)).foregroundStyle(device.isCurrent ? .white : .white.opacity(0.35))
                }
                .padding(.horizontal, 18)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                if device.isCurrent, device.volume != nil { setVolume(Float(drag.location.x / geo.size.width)) }
            }.onEnded { drag in
                if !device.isCurrent { choose(device) }
            })
        }
        .frame(height: 48).padding(.horizontal, 20)
        .foregroundStyle(.white)
    }
}
