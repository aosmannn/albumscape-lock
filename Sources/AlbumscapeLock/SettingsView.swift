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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(Settings.ink)
            w.contentView = NSHostingView(rootView: SettingsView(model: model, preview: preview))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var spotify = SpotifyAccount.shared
    let preview: () -> Void
    var scrolls = true  // a picture of the page (for checking its layout) can't show a scrolling area

    @AppStorage("showOnLock") private var showOnLock = true
    @AppStorage("idleShuffle") private var idleShuffle = true
    @AppStorage("videoMode") private var videoMode = PlayerModel.videoMode
    @AppStorage("animatedWallpaper") private var animatedWallpaper = true
    @AppStorage("coverWallpaper") private var coverWallpaper = false
    @AppStorage("clock24h") private var clock24h = false
    @AppStorage("spotifyClientID") private var clientID = ""
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            if scrolls { ScrollView { content } } else { content }
            footer
        }
        .background(Settings.ink)
        .foregroundStyle(Settings.cream)
        .frame(width: 560, height: scrolls ? 720 : nil)
    }

    private var content: some View {
                VStack(alignment: .leading, spacing: 10) {
                    header.padding(.bottom, 14)

                    section("A", "When it shows")
                    row("Show on the lock screen", "Your music fills the lock screen while a song plays") { toggle($showOnLock) }
                    row("When nothing's playing", "Leave the lock screen alone, or shuffle your albums' animated covers", below: true) {
                        segments(["Leave it", "My albums"], selected: idleShuffle ? 1 : 0) { idleShuffle = $0 == 1; if !idleShuffle { model.skipIdleOff() } }
                    }
                    row("Music videos", "A clip of the song's official video", below: true) {
                        segments(["If no animation", "Always", "Off"], selected: ["noMotion", "always", "off"].firstIndex(of: videoMode) ?? 1) {
                            videoMode = ["noMotion", "always", "off"][$0]; model.videoSettingChanged()
                        }
                    }
                    row("Lyrics", "Synced lyrics when available (click the L on the lock screen)") { toggle($model.lyricsOn) }

                    section("B", "Desktop and wallpaper").padding(.top, 10)
                    row("Animated wallpaper", "The animated cover plays behind your desktop icons") { toggle($animatedWallpaper) }
                    row("Cover on the lock screen wallpaper", "For songs with no animation, the cover becomes your wallpaper while locked") { toggle($coverWallpaper) }

                    section("C", "Spotify").padding(.top, 10)
                    row(spotify.connected ? "Connected" : "Not connected", "Shows which songs you've liked; the heart likes and unlikes") {
                        Button(spotify.connected ? "DISCONNECT" : "CONNECT") { spotify.connected ? spotify.disconnect() : spotify.connect() }
                            .buttonStyle(OutlineButton()).disabled(clientID.isEmpty && !spotify.connected)
                    }
                    row("Client ID", "From your own app at developer.spotify.com (see the advanced setup page)", below: true) {
                        TextField("Paste your Spotify Client ID", text: $clientID)
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                            .padding(10).background(RoundedRectangle(cornerRadius: 6).stroke(Settings.line))
                    }

                    section("D", "Other").padding(.top, 10)
                    row("24-hour clock", "17:30 instead of 5:30") { toggle($clock24h) }
                    row("Open at login", "Starts quietly in the menu bar when you log in") {
                        toggle(Binding(get: { openAtLogin }, set: { on in
                            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                            catch { Debug.log("login item: \(error)") }
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }))
                    }

                    Text("On the lock screen: click the picture to make it small · click L for lyrics · with nothing playing, click to skip a cover")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Settings.cream.opacity(0.45))
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 14)
                }
                .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 20)
    }

    private var footer: some View {
            HStack(spacing: 12) {
                Spacer()
                Button("SHOW IT NOW", action: preview).buttonStyle(OutlineButton())
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
            .background(Settings.ink.overlay(Rectangle().fill(Settings.line).frame(height: 1), alignment: .top))
    }

    private var header: some View {
        HStack(spacing: 16) {
            Group {
                if let cover = model.art?.coverURL {
                    AsyncImage(url: cover) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Settings.card }
                } else {
                    Image(nsImage: NSApp.applicationIconImage).resizable()
                }
            }
            .frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text("ALBUMSCAPE LOCK").font(.system(size: 30, weight: .black).width(.condensed))
                Text(model.track.map { "NOW PLAYING: \($0.title) · \($0.artist)".uppercased() } ?? "NOTHING PLAYING")
                    .font(.system(size: 11, design: .monospaced)).kerning(1.2).foregroundStyle(Settings.cream.opacity(0.6)).lineLimit(1)
            }
        }
    }

    private func section(_ letter: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(letter).foregroundStyle(Settings.rose)
                Text(title.uppercased())
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced)).kerning(2)
            Rectangle().fill(Settings.cream.opacity(0.8)).frame(height: 1)
        }
    }

    private func row<Control: View>(_ title: String, _ detail: String, below: Bool = false, @ViewBuilder control: () -> Control) -> some View {
        let text = VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(Settings.cream.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
        }
        return Group {
            if below {
                VStack(alignment: .leading, spacing: 12) { text; control() }
            } else {
                HStack(spacing: 16) { text; Spacer(minLength: 8); control() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Settings.card))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Settings.line))
    }

    private func toggle(_ value: Binding<Bool>) -> some View {
        Toggle("", isOn: value).toggleStyle(PillToggle()).labelsHidden()
    }

    private func segments(_ titles: [String], selected: Int, pick: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(titles.indices, id: \.self) { i in
                Button { withAnimation(.easeOut(duration: 0.15)) { pick(i) } } label: {
                    Text(titles[i].uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced)).kerning(1)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(i == selected ? Settings.cream : Settings.cream.opacity(0.5))
                        .background(i == selected ? Settings.cream.opacity(0.08) : .clear)
                        .overlay(alignment: .bottom) { if i == selected { Rectangle().fill(Settings.rose).frame(height: 2) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < titles.count - 1 { Rectangle().fill(Settings.line).frame(width: 1) }
            }
        }
        .overlay(Rectangle().stroke(Settings.line))
    }
}

/// The Windows app's square outlined button.
struct OutlineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .monospaced)).kerning(2)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .overlay(Rectangle().stroke(Settings.cream.opacity(0.85), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
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
