import AppKit

/// Whatever the Mac itself says is playing, from any app: a video or song in a browser tab, Tidal, a podcast. A small
/// helper library (Native/mediaremote.m) runs inside /usr/bin/perl, which macOS allows to read it, and prints one line a
/// second; this reads them and sends play, pause, next, back and seek the other way. It starts when first asked.
@MainActor
final class SystemNowPlaying {
    static let shared = SystemNowPlaying()
    static let bundle = "system"  // Track.source for songs from here
    static var enabled: Bool { UserDefaults.standard.object(forKey: "systemSource") as? Bool ?? true }

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var latest: [String: Any]?
    private var lastLine = Date.distantPast
    private var started = false
    private var failures = 0

    private var libraryURL: URL? { Bundle.main.url(forResource: "mediaremote", withExtension: "dylib") }

    /// The playing (or paused) track from the system, or nil.
    func read() -> Track? {
        guard Self.enabled else { return nil }
        start()
        guard let d = latest, Date().timeIntervalSince(lastLine) < 4, let title = d["title"] as? String, !title.isEmpty else { return nil }
        return Track(title: title, artist: d["artist"] as? String ?? "", album: d["album"] as? String ?? "",
                     isPlaying: d["playing"] as? Bool ?? false, position: d["elapsed"] as? Double ?? 0,
                     duration: d["duration"] as? Double ?? 0, source: Self.bundle, appBundle: d["app"] as? String ?? "")
    }

    func send(_ command: String) {
        guard let input, let data = (command + "\n").data(using: .utf8) else { return }
        try? input.write(contentsOf: data)
    }

    private func start() {
        guard !started, failures < 4, let lib = libraryURL else { return }
        started = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "use DynaLoader; DynaLoader::dl_load_file($ARGV[0], 0) or die; sleep;", lib.path]
        let out = Pipe(), inn = Pipe()
        p.standardOutput = out
        p.standardInput = inn
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            Task { @MainActor in self?.take(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                Debug.log("system now playing: helper ended")
                self.started = false; self.process = nil; self.input = nil; self.failures += 1
            }
        }
        do {
            try p.run()
            process = p; input = inn.fileHandleForWriting
            Debug.log("system now playing: helper started")
        } catch { started = false; failures += 1; Debug.log("system now playing: couldn't start (\(error))") }
    }

    private func take(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            lastLine = Date()
            if latest?["title"] as? String != obj["title"] as? String { Debug.log("system now playing: \((obj["title"] as? String) ?? "nothing") [\((obj["app"] as? String) ?? "?")] \((obj["timeout"] as? Bool) == true ? "(timed out)" : "")") }
            latest = obj
        }
    }
}
