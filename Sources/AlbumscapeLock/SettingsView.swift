//
//  SettingsView.swift
//
//  The settings page, laid out like the Windows Albumscape's: a header with what's playing, lettered sections of rows
//  (a title, a line of explanation, and the control on the right), and "Show it now" at the bottom. Every change is
//  saved at once.
//

import AppKit
import ServiceManagement
import SwiftUI

enum Settings {
    static let ink = Color(red: 0.078, green: 0.071, blue: 0.063)
    static let card = Color(red: 0.118, green: 0.106, blue: 0.094)
    static let line = Color(red: 0.93, green: 0.89, blue: 0.83).opacity(0.12)
    static let cream = Color(red: 0.93, green: 0.89, blue: 0.83)
    static let rose = Color(red: 0.85, green: 0.62, blue: 0.56)
}

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(model: PlayerModel, preview: @escaping () -> Void) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(Settings.ink)
            w.minSize = NSSize(width: 760, height: 520)
            w.contentView = NSHostingView(rootView: SettingsView(model: model, preview: preview))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// A sidebar of sections on the left, like Droppy's settings, in Albumscape's colours; the chosen section on the right.
struct SettingsView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var spotify = SpotifyAccount.shared
    let preview: () -> Void
    var scrolls = true  // a picture of the page (for checking its layout) can't show a scrolling area

    enum Page: String, CaseIterable, Identifiable {
        case general = "General", lockScreen = "Lock screen", videos = "Music videos", desktop = "Desktop", spotify = "Spotify", about = "About"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .lockScreen: return "lock.fill"
            case .videos: return "play.rectangle.fill"
            case .desktop: return "macwindow"
            case .spotify: return "heart.fill"
            case .about: return "info.circle.fill"
            }
        }
        var tint: Color {
            switch self {
            case .general: return Color(white: 0.45)
            case .lockScreen: return Color(red: 0.36, green: 0.42, blue: 0.95)
            case .videos: return Color(red: 0.90, green: 0.25, blue: 0.18)
            case .desktop: return Color(red: 0.22, green: 0.62, blue: 0.85)
            case .spotify: return Color(red: 0.12, green: 0.73, blue: 0.33)
            case .about: return Settings.rose
            }
        }
        /// Words each page answers to in the search box.
        var keywords: String {
            switch self {
            case .general: return "lock screen login start clock 24-hour"
            case .lockScreen: return "nothing playing shuffle albums lyrics preview show it now"
            case .videos: return "music videos youtube clip animation"
            case .desktop: return "wallpaper animated cover desktop icons"
            case .spotify: return "spotify heart liked songs client id connect"
            case .about: return "version github credits license"
            }
        }
    }

    @State private var page: Page = .general
    @State private var search = ""

    @AppStorage("showOnLock") private var showOnLock = true
    @AppStorage("idleShuffle") private var idleShuffle = true
    @AppStorage("videoMode") private var videoMode = PlayerModel.videoMode
    @AppStorage("animatedWallpaper") private var animatedWallpaper = true
    @AppStorage("coverWallpaper") private var coverWallpaper = false
    @AppStorage("clock24h") private var clock24h = false
    @AppStorage("audioVisualizer") private var audioVisualizer = true
    @AppStorage("spotifyClientID") private var clientID = ""
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    private var pages: [Page] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? Page.allCases : Page.allCases.filter { $0.rawValue.lowercased().contains(q) || $0.keywords.contains(q) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Settings.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(page.rawValue).font(.system(size: 22, weight: .bold)).padding(.horizontal, 32).padding(.top, 34).padding(.bottom, 14)
                Group {
                    if scrolls { ScrollView { detail.padding(.horizontal, 32).padding(.bottom, 32) } } else { detail.padding(.horizontal, 32).padding(.bottom, 32) }
                }
                .id(page)
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .animation(.easeOut(duration: 0.18), value: page)
        .background(Settings.ink)
        .foregroundStyle(Settings.cream)
        .frame(minWidth: 760, minHeight: scrolls ? 520 : nil)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).opacity(0.5)
                TextField("Search settings", text: $search).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Settings.cream.opacity(0.07)))
            .padding(.top, 44).padding(.bottom, 12)

            HStack(spacing: 12) {
                cover.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Albumscape Lock").font(.system(size: 15, weight: .bold))
                    Text(model.track.map { "\($0.title) · \($0.artist)" } ?? "Nothing playing")
                        .font(.system(size: 11)).opacity(0.55).lineLimit(1)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 14)

            ForEach(pages) { item in SidebarItem(page: item, selected: page == item) { page = item } }
            Spacer()
            Button(action: preview) { Text("SHOW IT NOW").frame(maxWidth: .infinity) }
                .buttonStyle(OutlineButton()).pointer()
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 14)
        .frame(width: 250)
        .background(Settings.card.opacity(0.6))
    }

    @ViewBuilder private var cover: some View {
        if let url = model.art?.coverURL {
            AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Settings.card }
        } else {
            Image(nsImage: NSApp.applicationIconImage).resizable()
        }
    }

    // MARK: Pages

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch page {
            case .general:
                group {
                    row("Show on the lock screen", "Your music fills the lock screen while a song plays") { toggle($showOnLock) }
                    row("Open at login", "Starts quietly in the menu bar when you log in") {
                        toggle(Binding(get: { openAtLogin }, set: { on in
                            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                            catch { Debug.log("login item: \(error)") }
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }))
                    }
                    row("24-hour clock", "17:30 instead of 5:30", last: true) { toggle($clock24h) }
                }
            case .lockScreen:
                group {
                    row("When nothing's playing", "Leave the lock screen alone, or shuffle the animated covers of albums you've played", below: true) {
                        segments(["Leave it", "My albums"], selected: idleShuffle ? 1 : 0) { idleShuffle = $0 == 1; model.skipIdleOff() }
                    }
                    row("Lyrics", "Synced lyrics when available (click the L on the lock screen)") { toggle($model.lyricsOn) }
                    row("Audio visualizer", "Bars that move with the real sound, in the song's colour. macOS asks once for System Audio permission") {
                        HStack(spacing: 12) {
                            Button("ALLOW") { AudioSpectrum.shared.requestAccess() }.buttonStyle(OutlineButton()).pointer()
                            toggle($audioVisualizer)
                        }
                    }
                    row("Try it", "See it full screen for 20 seconds", last: true) { Button("SHOW IT NOW", action: preview).buttonStyle(OutlineButton()).pointer() }
                }
                hint("On the lock screen: click the picture to make it small · click L for lyrics · with nothing playing, click to skip a cover")
            case .videos:
                group {
                    row("Music videos", "A clip of the song's official video, in step with the song", below: true, last: true) {
                        segments(["If no animation", "Always", "Off"], selected: ["noMotion", "always", "off"].firstIndex(of: videoMode) ?? 1) {
                            videoMode = ["noMotion", "always", "off"][$0]; model.videoSettingChanged()
                        }
                    }
                }
                hint("If no animation: the album's animated cover plays, and a video only for albums without one. Off: animated covers only.")
            case .desktop:
                group {
                    row("Animated wallpaper", "The animated cover plays behind your desktop icons") { toggle($animatedWallpaper) }
                    row("Cover on the lock screen wallpaper", "For songs with no animation, the cover becomes your wallpaper while locked", last: true) { toggle($coverWallpaper) }
                }
            case .spotify:
                group {
                    row(spotify.connected ? "Connected" : "Not connected", "Shows which songs you've liked; the heart likes and unlikes") {
                        Button(spotify.connected ? "DISCONNECT" : "CONNECT") { spotify.connected ? spotify.disconnect() : spotify.connect() }
                            .buttonStyle(OutlineButton()).pointer().disabled(clientID.isEmpty && !spotify.connected)
                    }
                    row("Client ID", "From your own app at developer.spotify.com (see the advanced setup page)", below: true, last: true) {
                        TextField("Paste your Spotify Client ID", text: $clientID)
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                            .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Settings.ink))
                    }
                }
            case .about:
                group {
                    HStack(spacing: 16) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ALBUMSCAPE LOCK").font(.system(size: 26, weight: .black).width(.condensed))
                            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                                .font(.system(size: 12, design: .monospaced)).opacity(0.6)
                        }
                    }
                    .padding(18)
                    Rectangle().fill(Settings.line).frame(height: 1)
                    row("GitHub", "Updates, the source and the advanced setup page", last: true) {
                        Button("OPEN") { NSWorkspace.shared.open(URL(string: "https://github.com/aosmannn/albumscape-lock")!) }.buttonStyle(OutlineButton()).pointer()
                    }
                }
                hint("Lyrics from LRCLIB · covers and animations from Apple Music")
            }
        }
    }

    // MARK: Pieces

    /// Rows of one page in a single rounded card, divided by thin lines, as Droppy groups them.
    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Settings.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Settings.line))
    }

    private func row<Control: View>(_ title: String, _ detail: String, below: Bool = false, last: Bool = false, @ViewBuilder control: () -> Control) -> some View {
        HoverRow(last: last) {
            let text = VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Settings.cream.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
            if below {
                VStack(alignment: .leading, spacing: 12) { text; control() }
            } else {
                HStack(spacing: 16) { text; Spacer(minLength: 8); control() }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Settings.cream.opacity(0.45)).padding(.horizontal, 4)
    }

    private func toggle(_ value: Binding<Bool>) -> some View {
        Toggle("", isOn: value).toggleStyle(PillToggle()).labelsHidden().pointer()
    }

    private func segments(_ titles: [String], selected: Int, pick: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(titles.indices, id: \.self) { i in
                SegmentButton(title: titles[i], selected: i == selected) { withAnimation(.easeOut(duration: 0.15)) { pick(i) } }
                if i < titles.count - 1 { Rectangle().fill(Settings.line).frame(width: 1) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Settings.line))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A row that lights up a little under the mouse.
private struct HoverRow<Content: View>: View {
    var last = false
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Settings.cream.opacity(hovering ? 0.035 : 0))
            .overlay(alignment: .bottom) { if !last { Rectangle().fill(Settings.line).frame(height: 1).padding(.leading, 18) } }
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

private struct SidebarItem: View {
    let page: SettingsView.Page
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(page.tint))
                Text(page.rawValue).font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Settings.rose.opacity(0.32) : Settings.cream.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .pointer()
    }
}

private struct SegmentButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced)).kerning(1)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .foregroundStyle(selected ? Settings.cream : Settings.cream.opacity(hovering ? 0.8 : 0.5))
                .background(selected ? Settings.cream.opacity(0.09) : Settings.cream.opacity(hovering ? 0.04 : 0))
                .overlay(alignment: .bottom) { if selected { Rectangle().fill(Settings.rose).frame(height: 2) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .pointer()
    }
}

extension View {
    /// The pointing-hand cursor over anything you can click.
    func pointer() -> some View {
        onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}

/// The Windows app's square outlined button.
struct OutlineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .monospaced)).kerning(2)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(Rectangle().fill(Settings.cream.opacity(configuration.isPressed ? 0.12 : 0)))
            .overlay(Rectangle().stroke(Settings.cream.opacity(0.85), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The Windows app's switch: a rose pill with a dark knob when on, a dim outline when off.
struct PillToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { configuration.isOn.toggle() } } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Settings.rose : Settings.cream.opacity(0.08))
                    .overlay(Capsule().stroke(configuration.isOn ? Color.clear : Settings.cream.opacity(0.35)))
                Circle().fill(configuration.isOn ? Settings.ink : Settings.cream.opacity(0.55))
                    .frame(width: 16, height: 16).padding(4)
            }
            .frame(width: 44, height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
