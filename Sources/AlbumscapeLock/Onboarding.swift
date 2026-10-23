//
//  Onboarding.swift
//
//  The first-run guide, laid out like the Windows Albumscape's four steps: a welcome, allow Spotify and Music, make it
//  yours, and "you're all set". Shown the first time the app opens, and again from Settings > About > Run setup.
//

import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class OnboardingWindow {
    static let shared = OnboardingWindow()
    private var window: NSWindow?

    static var done: Bool { UserDefaults.standard.bool(forKey: "onboarded") }

    func show(model: PlayerModel, preview: @escaping () -> Void) {
        window?.close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(Settings.ink)
        w.contentView = NSHostingView(rootView: OnboardingView(model: model, preview: preview, close: { [weak self] in
            UserDefaults.standard.set(true, forKey: "onboarded")
            self?.window?.close()
        }))
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct OnboardingView: View {
    @ObservedObject var model: PlayerModel
    let preview: () -> Void
    let close: () -> Void
    var startStep = 0
    @ObservedObject private var spotify = SpotifyAccount.shared
    @State private var step: Int
    @State private var allowed = false
    @State private var showSpotify = false

    @AppStorage("showOnLock") private var showOnLock = true
    @AppStorage("idleShuffle") private var idleShuffle = true
    @AppStorage("videoMode") private var videoMode = PlayerModel.videoMode
    @AppStorage("animatedWallpaper") private var animatedWallpaper = true
    @AppStorage("spotifyClientID") private var clientID = ""
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    init(model: PlayerModel, preview: @escaping () -> Void, close: @escaping () -> Void, startStep: Int = 0) {
        self.model = model; self.preview = preview; self.close = close; self.startStep = startStep
        _step = State(initialValue: startStep)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: allow
                case 2: yours
                default: finished
                }
            }
            .id(step)
            .transition(.opacity.combined(with: .offset(y: 8)))
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 44).padding(.top, 52).padding(.bottom, 30)
        .frame(width: 640, height: 600, alignment: .topLeading)
        .background(
            ZStack { Settings.ink; RadialGradient(colors: [Color(red: 0.55, green: 0.12, blue: 0.08).opacity(step == 0 ? 0.35 : 0.0), .clear], center: .top, startRadius: 0, endRadius: 420) }
        )
        .foregroundStyle(Settings.cream)
        .animation(.easeOut(duration: 0.22), value: step)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.04)).frame(width: 150, height: 150).rotationEffect(.degrees(-6)).offset(x: -90)
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.04)).frame(width: 150, height: 150).rotationEffect(.degrees(6)).offset(x: 90)
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 170, height: 170).shadow(color: .black.opacity(0.5), radius: 20, y: 10)
            }
            .frame(maxWidth: .infinity).padding(.bottom, 14)
            Text("ALBUMSCAPE LOCK").font(.system(size: 11, design: .monospaced)).kerning(2).opacity(0.6)
            Text("YOUR MUSIC,\nFULL SCREEN.").font(.system(size: 54, weight: .black).width(.condensed)).lineSpacing(-8)
            Text("Apple Music's animated covers and music videos fill your lock screen the moment you lock your Mac, for whatever you're playing.")
                .font(.system(size: 15)).foregroundStyle(Settings.cream.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Settings.line).frame(height: 1)
            HStack(alignment: .top, spacing: 28) {
                feature("Spotify or Music", "Whatever you play")
                feature("Synced lyrics", "Word by word")
                feature("Out of the way", "Click to shrink it")
            }
        }
    }

    private func feature(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Settings.cream.opacity(0.5))
        }
    }

    private var allow: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepLabel("STEP 2 OF 4")
            Text("SPOTIFY AND MUSIC").font(.system(size: 44, weight: .black).width(.condensed))
            Text("Albumscape Lock needs to see what's playing. macOS asks once; choose Allow. Open Spotify or Music and play a song, then press the button.")
                .font(.system(size: 15)).foregroundStyle(Settings.cream.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
            card {
                HStack(spacing: 14) {
                    Image(systemName: allowed || model.track != nil ? "checkmark.square.fill" : "square").font(.system(size: 26))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.track != nil ? "Ready to go" : "Allow Albumscape Lock").font(.system(size: 14, weight: .semibold))
                        Text(model.track.map { "Seeing: \($0.title) · \($0.artist)" } ?? "Then it shows here what it sees").font(.system(size: 12)).foregroundStyle(Settings.cream.opacity(0.55))
                    }
                    Spacer()
                    Button("ALLOW") { askForAccess() }.buttonStyle(OutlineButton()).pointer()
                }
            }
            card {
                VStack(alignment: .leading, spacing: 12) {
                    Button { withAnimation { showSpotify.toggle() } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Spotify's heart for liked songs?").font(.system(size: 14, weight: .semibold))
                                Text("Optional. Needs your own free Spotify app (see the advanced setup page).").font(.system(size: 12)).foregroundStyle(Settings.cream.opacity(0.55))
                            }
                            Spacer()
                            Image(systemName: showSpotify ? "chevron.up" : "chevron.down").font(.system(size: 11))
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).pointer()
                    if showSpotify {
                        TextField("Paste your Spotify Client ID", text: $clientID)
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Settings.ink))
                        Button(spotify.connected ? "CONNECTED" : "CONNECT") { if !spotify.connected { spotify.connect() } }
                            .buttonStyle(OutlineButton()).pointer().disabled(clientID.isEmpty)
                    }
                }
            }
        }
    }

    private var yours: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepLabel("STEP 3 OF 4")
            Text("MAKE IT YOURS").font(.system(size: 44, weight: .black).width(.condensed))
            Text("You can change any of this later in Settings.").font(.system(size: 15)).foregroundStyle(Settings.cream.opacity(0.75))
            card { choice("Show on the lock screen", "Your music fills it while a song plays") { PillToggleBinding($showOnLock) } }
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Music videos").font(.system(size: 14, weight: .semibold))
                    Text("A clip of the song's official video").font(.system(size: 12)).foregroundStyle(Settings.cream.opacity(0.55))
                    HStack(spacing: 0) {
                        ForEach(Array(["If no animation", "Always", "Off"].enumerated()), id: \.offset) { i, title in
                            SegmentButton(title: title, selected: videoMode == ["noMotion", "always", "off"][i]) { videoMode = ["noMotion", "always", "off"][i] }
                            if i < 2 { Rectangle().fill(Settings.line).frame(width: 1) }
                        }
                    }.overlay(RoundedRectangle(cornerRadius: 8).stroke(Settings.line)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            card { choice("When nothing's playing", "Shuffle the animated covers of albums you've played") { PillToggleBinding($idleShuffle) } }
            card { choice("Animated wallpaper", "The animated cover behind your desktop icons too") { PillToggleBinding($animatedWallpaper) } }
            card {
                choice("Open at login", "Starts quietly in the menu bar") {
                    PillToggleBinding(Binding(get: { openAtLogin }, set: { on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { Debug.log("login item: \(error)") }
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }))
                }
            }
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepLabel("STEP 4 OF 4")
            Text("YOU'RE ALL SET").font(.system(size: 44, weight: .black).width(.condensed))
            Text("Play a song in Spotify or Music, then lock your Mac.").font(.system(size: 15)).foregroundStyle(Settings.cream.opacity(0.75))
            card {
                HStack(spacing: 14) {
                    Group {
                        if let url = model.art?.coverURL { AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Settings.ink } }
                        else { Image(nsImage: NSApp.applicationIconImage).resizable() }
                    }.frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NOW PLAYING").font(.system(size: 10, design: .monospaced)).kerning(1.5).opacity(0.5)
                        Text(model.track?.title ?? "Nothing yet").font(.system(size: 22, weight: .black).width(.condensed)).lineLimit(1)
                        Text(model.track.map { "\($0.artist) — \($0.album)".uppercased() } ?? "PLAY A SONG TO TRY IT").font(.system(size: 10, design: .monospaced)).opacity(0.55).lineLimit(1)
                    }
                    Spacer()
                }
            }
            Text("GOOD TO KNOW").font(.system(size: 10, design: .monospaced)).kerning(1.5).opacity(0.5).padding(.top, 8)
            tip("Click", "the picture to make it small, and again to enlarge it")
            tip("L", "turns lyrics on or off (the white square by the title)")
            tip("Click", "anywhere with nothing playing to skip to another animated cover")
            tip("Settings", "open Albumscape Lock from Applications any time")
        }
    }

    // MARK: Pieces

    private func stepLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, design: .monospaced)).kerning(2).opacity(0.55)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Settings.card))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Settings.line))
    }

    private func choice<Control: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Settings.cream.opacity(0.55))
            }
            Spacer()
            control()
        }
    }

    private func tip(_ key: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text(key).font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 4).overlay(Rectangle().stroke(Settings.cream.opacity(0.8)))
                .frame(minWidth: 72, alignment: .leading)
            Text(text).font(.system(size: 13)).foregroundStyle(Settings.cream.opacity(0.8))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in Rectangle().fill(i == step ? Settings.cream : Settings.cream.opacity(0.25)).frame(width: 24, height: 2) }
            }
            Spacer()
            if step == 3 {
                Button("SHOW IT NOW") { preview() }.buttonStyle(OutlineButton()).pointer()
                Button("DONE") { close() }.buttonStyle(FilledButton()).pointer()
            } else {
                if step > 0 { Button("BACK") { step -= 1 }.buttonStyle(OutlineButton()).pointer() }
                Button(step == 0 ? "GET STARTED" : (step == 2 ? "FINISH" : "NEXT")) { step += 1 }.buttonStyle(FilledButton(red: step == 0)).pointer()
            }
        }
    }

    /// Asks Spotify and Music about the current song, which is what makes macOS show its Allow question.
    private func askForAccess() {
        for id in ["com.spotify.client", "com.apple.Music"] where NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == id }) {
            _ = NSAppleScript(source: "tell application id \"\(id)\" to return player state as string")?.executeAndReturnError(nil)
        }
        allowed = true
    }
}

private struct PillToggleBinding: View {
    @Binding var value: Bool
    init(_ value: Binding<Bool>) { _value = value }
    var body: some View { Toggle("", isOn: $value).toggleStyle(PillToggle()).labelsHidden().pointer() }
}

/// The filled call-to-action button of the Windows app's guide: light, or red on the welcome step.
struct FilledButton: ButtonStyle {
    var red = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .monospaced)).kerning(2)
            .padding(.horizontal, 22).padding(.vertical, 12)
            .foregroundStyle(red ? Color.white : Color(red: 0.07, green: 0.07, blue: 0.06))
            .background(Rectangle().fill(red ? Color(red: 0.89, green: 0.26, blue: 0.19) : Settings.cream))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
