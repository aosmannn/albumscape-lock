import AppKit
import SwiftUI

/// Looks for a newer release on GitHub: once at launch, then every twelve hours, and when asked in Settings. It only
/// tells you (a menu item and the About page); installing is dragging the new app over the old one, as the first time.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()
    static let latestURL = URL(string: "https://api.github.com/repos/aosmannn/albumscape-lock/releases/latest")!

    @Published var newVersion: String?   // set when a release newer than this one exists
    @Published var status = ""
    @Published var checking = false
    private(set) var downloadURL = URL(string: "https://github.com/aosmannn/albumscape-lock/releases/latest")!

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdateCheck") }
    }

    /// Starts the quiet background checks.
    func start() {
        Task { await check(manual: false) }
        Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updates.shared.check(manual: false) }
        }
    }

    func check(manual: Bool) async {
        guard manual || Self.autoCheck, !checking else { return }
        checking = true
        defer { checking = false }
        var request = URLRequest(url: Self.latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                if manual { status = "Couldn't find release information" }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if Self.isNewer(latest, than: Self.current) {
                newVersion = latest
                let assets = json["assets"] as? [[String: Any]] ?? []
                if let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                   let link = (dmg["browser_download_url"] as? String).flatMap(URL.init(string:)) { downloadURL = link }
                else if let page = (json["html_url"] as? String).flatMap(URL.init(string:)) { downloadURL = page }
                status = "Version \(latest) is available"
            } else {
                newVersion = nil
                status = "You're up to date (\(Self.current))"
            }
        } catch {
            if manual { status = "Couldn't reach GitHub" }
        }
    }

    func download() { NSWorkspace.shared.open(downloadURL) }

    /// 0.10.1 is newer than 0.9: compared number by number.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
