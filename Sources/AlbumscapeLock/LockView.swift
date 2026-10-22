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
                SongInfo(track: model.track, position: model.position(at: context.date), accent: accent, album: model.art?.album).padding(48)
            }
            LockClock().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 70)
            LyricsBadge(on: model.lyricsOn, hasLyrics: !model.lyrics.isEmpty, accent: accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.leading, 32).padding(.top, 60)
            if let toast = model.toast {
                Text(toast).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8).background(Capsule().fill(.black.opacity(0.55)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 60)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The date and time at the top, the way the Mac's own lock screen shows them: the full-screen video covers that one.
struct LockClock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                Text(context.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 26, weight: .semibold))
                Text(context.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale.current)).replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: ""))
                    .font(.system(size: 124, weight: .bold, design: .rounded)).monospacedDigit()
                    .padding(.top, -10)
            }
            .foregroundStyle(.white.opacity(0.95))
            .shadow(color: .black.opacity(0.45), radius: 16, y: 2)
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
    @State private var ready: String?

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
        return [showVideo ? model.video.map(Source.youtube) : nil, model.art?.motionURL.map(Source.file), model.art?.videoURL.map(Source.file)]
            .compactMap { $0 }.filter { !failed.contains($0.key) }
    }

    var body: some View {
        ZStack {
            if let cover = model.art?.coverURL {
                AsyncImage(url: cover) { $0.resizable().aspectRatio(contentMode: .fill).frame(maxWidth: .infinity, maxHeight: .infinity).clipped() } placeholder: { Color.clear }
            }
            ForEach(sources, id: \.key) { source in
                let shown = sources.first { $0.key == ready } ?? sources.first
                player(source)
                    // YouTube's own pause symbol and "up next" panel never show: paused, the cover is what you see
                    .opacity(source == shown && ready == source.key && (isYouTube(source) == false || model.track?.isPlaying == true) ? 1 : 0)
                    .animation(.easeInOut(duration: 0.6), value: ready)
            }
        }
        .clipped()
    }

    private func isYouTube(_ source: Source) -> Bool { if case .youtube = source { return true } else { return false } }

    @ViewBuilder private func player(_ source: Source) -> some View {
        switch source {
        case .youtube(let v):
            let embed = YouTubeEmbed(video: v, startAt: model.track?.position ?? 0,
                                     playing: model.track?.isPlaying == true,
                                     position: { [model] in model.position(at: Date()) + v.offset },
                                     onReady: { Debug.log("yt ready"); ready = source.key },
                                     onFailure: { Debug.log("yt FAILED"); failed.insert(source.key) })
            if let side = thumbnailSide {
                let layout: CGFloat = 320
                embed.frame(width: layout, height: layout).scaleEffect(side / layout * 1.75).frame(width: side, height: side).clipped()
            } else {
                embed
            }
        case .file(let url):
            LoopingVideo(url: url,
                         onReady: { Debug.log("file ready"); if ready == nil { ready = source.key } },
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
                Text(track.title).font(.system(size: 36, weight: .bold)).lineLimit(1)
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

    static let size = CGSize(width: 410, height: 160)

    var body: some View {
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
                            Text("L").font(.system(size: 9, weight: .heavy, design: .rounded))
                                .foregroundStyle(model.lyricsOn ? Color.black.opacity(0.85) : Color.white.opacity(0.9))
                                .frame(width: 15, height: 15)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(model.lyricsOn ? accent : Color.white.opacity(0.22)))
                        }.buttonStyle(.plain).opacity(model.lyrics.isEmpty ? 0.5 : 1)
                    }
                    Text(model.track?.artist ?? "").font(.system(size: 12.5)).opacity(0.8).lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                let position = model.position(at: context.date)
                let duration = model.track?.duration ?? 0
                HStack(spacing: 10) {
                    Text(timeString(position)).frame(width: 34, alignment: .leading)
                    Capsule().fill(.white.opacity(0.28)).frame(height: 4)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Capsule().fill(accent)
                                    .frame(width: geo.size.width * (duration > 0 ? min(1, max(0, position / duration)) : 0))
                            }
                        }
                    Text("-" + timeString(max(0, duration - position)))
                        .frame(width: 38, alignment: .trailing)
                }
            }
            .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(accent)

            ZStack {
                HStack(spacing: 38) {
                    control("backward.fill", 22, model.previous)
                    control(model.track?.isPlaying == true ? "pause.fill" : "play.fill", 28, model.playPause)
                    control("forward.fill", 22, model.next)
                }
                HStack {
                    Button { model.toggleLike() } label: {
                        Image(systemName: model.liked ? "heart.fill" : "heart").font(.system(size: 16))
                            .foregroundStyle(model.liked ? accent : .white).opacity(model.liked ? 1 : 0.85)
                    }.buttonStyle(.plain)
                    Spacer()
                    Image(systemName: "airplayaudio").font(.system(size: 16)).opacity(0.85)
                }
            }
            .frame(height: 30)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        .padding(.horizontal, 14).padding(.vertical, 13)
        .frame(width: Self.size.width, height: Self.size.height)
        .modifier(GlassBackground(enabled: nativeGlass == false))
        .background { if let backdrop { LiquidGlassCard(backdrop: backdrop, size: Self.size) } }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Text(toast).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(.black.opacity(0.6)))
                    .padding(.top, 6).transition(.opacity)
            }
        }
    }

    private var accent: Color { model.art?.accent ?? .white }

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

private struct GlassBackground: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View { if enabled { content.liquidGlass(cornerRadius: 30) } else { content } }
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
    /// The card as the ported shader draws it; the SwiftUI approximation below is the fallback.
    var glass: NSImage?
}

/// macOS's own glass samples whatever is behind its window, and behind this window (on the lock screen) there is nothing
/// it can see, so it comes out as plain see-through. This draws what glass does with the wallpaper instead: the picture
/// behind the card, magnified a little like a lens, softened and brightened in colour, with a light rim that is
/// brightest at the corners facing the light, a soft sheen across the top and a glow just inside the edge.
struct LiquidGlassCard: View {
    let backdrop: GlassBackdrop
    let size: CGSize
    private let radius: CGFloat = 40

    var body: some View {
        if let glass = backdrop.glass {
            Image(nsImage: glass).resizable().frame(width: size.width, height: size.height)
        } else {
            approximation
        }
    }

    @ViewBuilder private var approximation: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let centre = UnitPoint(x: (backdrop.origin.x + size.width / 2) / backdrop.screenSize.width,
                               y: (backdrop.origin.y + size.height / 2) / backdrop.screenSize.height)
        ZStack {
            Image(nsImage: backdrop.image).resizable().scaledToFill()
                .frame(width: backdrop.screenSize.width, height: backdrop.screenSize.height).clipped()
                .blur(radius: 9)
                .scaleEffect(1.07, anchor: centre)
                .saturation(1.45).brightness(0.05)
                .offset(x: -backdrop.origin.x, y: -backdrop.origin.y)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            shape.fill(Color.black.opacity(0.2))
            shape.fill(LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.04), .clear], startPoint: .top, endPoint: .center))
            shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 7).blur(radius: 6).clipShape(shape)
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.1), .white.opacity(0.35)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.4)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
    }
}
