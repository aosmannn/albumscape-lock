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
    @ObservedObject private var updates = Updates.shared
    @ObservedObject private var spotify = SpotifyAccount.shared
    @ObservedObject private var link = PeerLink.shared
    let preview: () -> Void
    var scrolls = true  // a picture of the page (for checking its layout) can't show a scrolling area

    enum Page: String, CaseIterable, Identifiable {
        case general = "General", lockScreen = "Lock screen", videos = "Music videos", desktop = "Desktop", spotify = "Spotify", lastfm = "Other players", pc = "Windows PC", about = "About"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .lockScreen: return "lock.fill"
            case .videos: return "play.rectangle.fill"
            case .desktop: return "macwindow"
            case .spotify: return "heart.fill"
            case .lastfm: return "music.note.list"
            case .pc: return "desktopcomputer"
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
            case .lastfm: return Color(red: 0.85, green: 0.10, blue: 0.20)
            case .pc: return Color(red: 0.25, green: 0.52, blue: 0.96)
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
            case .lastfm: return "last.fm lastfm scrobble other players tidal youtube music browser phone iphone"
            case .pc: return "windows pc link visualizer bridge network"
            case .about: return "version github credits license"
            }
        }
    }

    @State private var page: Page = .general
    @State private var search = ""

    @AppStorage("showOnLock") private var showOnLock = true
    @AppStorage("displays") private var displays = "all"
    @AppStorage("lastfmOn") private var lastfmOn = false
    @AppStorage("lastfmUser") private var lastfmUser = ""
    @AppStorage("lastfmKey") private var lastfmKey = ""
    @AppStorage("idleShuffle") private var idleShuffle = true
    @AppStorage("videoMode") private var videoMode = PlayerModel.videoMode
    @AppStorage("animatedWallpaper") private var animatedWallpaper = true
    @AppStorage("coverWallpaper") private var coverWallpaper = false
    @AppStorage("clock24h") private var clock24h = false
    @AppStorage("linkPC") private var linkPC = false
    @AppStorage("pcAddress") private var pcAddress = ""
    @AppStorage("audioVisualizer") private var audioVisualizer = true
    @AppStorage("batterySaver") private var batterySaver = 20
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
                    if NSScreen.screens.count > 1 {
                        row("Displays", "With more than one screen, where the music shows", below: true) {
                            segments(["All displays", "Main display only"], selected: displays == "main" ? 1 : 0) { displays = $0 == 1 ? "main" : "all" }
                        }
                    }
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
                    row("Audio visualizer", "Bars that move with the real sound, in the song's colour. Listens to audio only, never your screen; macOS shows a small audio dot while it does") {
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
                if Power.onBattery != nil {
                    group {
                        row("Save battery", "Stops music videos, the visualizer and the animated desktop; the cover stays", below: true, last: true) {
                            segments(["Never", "Below 20%", "Below 40%", "On battery"], selected: [0, 20, 40, 100].firstIndex(of: batterySaver) ?? 1) {
                                batterySaver = [0, 20, 40, 100][$0]; model.videoSettingChanged()
                            }
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
            case .lastfm:
                group {
                    row("Show music from other players", "Tidal, YouTube Music in a browser, Spotify on your phone: anything that scrobbles to Last.fm") { toggle($lastfmOn) }
                    row("Last.fm username", "Your Last.fm account name", below: true) {
                        TextField("username", text: $lastfmUser)
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                            .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Settings.ink))
                    }
                    row("API key", "Free, from last.fm/api/account/create (any name). It only lets this app read your own listening", below: true, last: true) {
                        TextField("Paste your Last.fm API key", text: $lastfmKey)
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                            .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Settings.ink))
                    }
                }
                hint("Spotify and Music on this Mac always come first. Songs from here can't be paused or skipped from the lock screen, and the lyrics follow a clock that starts when the song is first seen, so they can be a few seconds off.")
            case .pc:
                group {
                    row("Link with my Windows PC", "The PC's sound moves this Mac's visualizer, and the Mac's moves the PC's. Only 48 small numbers travel, over your own network") {
                        toggle(Binding(get: { linkPC }, set: { linkPC = $0; PeerLink.shared.apply() }))
                    }
                    row("PC address", "Optional: the PC's address (like 192.168.1.20). Leave empty and the Mac answers whichever PC sends to it", below: true) {
                        TextField("Leave empty to find it automatically", text: $pcAddress)
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                            .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Settings.ink))
                    }
                    row("Status", link.status, last: true) { EmptyView() }
                }
                hint("On the PC, run windows-bridge/albumscape_bridge.py from the GitHub page. It needs Python and two small add-ons.")
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
                    aboutText("What it is", "Your music, full screen on your Mac's lock screen. When a song plays in Spotify or Apple Music and you lock your Mac, its album's animated cover (Apple Music's motion art), or its music video, fills the screen, with the time, synced lyrics and a small player you can open by clicking. With nothing playing, it shuffles the animated covers of albums you've played, on the lock screen and behind your desktop icons.")
                    aboutText("How to use it", "Lock your Mac while a song plays. Click the picture to make it small (play, next, back, the speaker list, a heart for Spotify's liked songs) and click again to enlarge it. Click the L for lyrics. With nothing playing, click anywhere to skip to another cover. Everything else is in these settings.")
                    aboutText("Permissions, and why", "Automation (Spotify, Music): reads what's playing and sends play, pause and skip. Local Network: only if you link a Windows PC. System Audio: only for the visualizer, which measures the sound's levels; it never records or stores audio and never looks at your screen, and macOS shows its small audio dot while it listens.")
                    aboutText("What it contacts", "Apple Music's public pages (covers and animations), LRCLIB (lyrics), YouTube (the video, in a hidden player), GitHub (to see if a newer version exists), and Spotify only if you connect it. What it learns about your albums is saved on this Mac, in ~/Library/Application Support/AlbumscapeLock. Nothing is sent anywhere else.")
                    aboutText("Good to know", "It draws over the lock screen with private macOS calls and reads Apple Music's public pages, so a Mac update or an Apple change can break it. It isn't on the App Store.")
                    Rectangle().fill(Settings.line).frame(height: 1)
                    row("Setup guide", "Go through the first-run steps again", last: false) {
                        Button("RUN SETUP") { OnboardingWindow.shared.show(model: model, preview: preview) }.buttonStyle(OutlineButton()).pointer()
                    }
                    row("Updates", updates.status.isEmpty ? "Version \(Updates.current). Checked at launch and every 12 hours" : updates.status, last: false) {
                        if updates.newVersion != nil {
                            Button("DOWNLOAD") { updates.download() }.buttonStyle(OutlineButton()).pointer()
                        } else {
                            Button(updates.checking ? "CHECKING…" : "CHECK") { Task { await updates.check(manual: true) } }.buttonStyle(OutlineButton()).pointer()
                        }
                    }
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

    private func aboutText(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(body).font(.system(size: 12.5)).foregroundStyle(Settings.cream.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
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

struct SegmentButton: View {
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
