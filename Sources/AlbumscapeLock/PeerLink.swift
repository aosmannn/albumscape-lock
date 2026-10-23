//
//  PeerLink.swift
//
//  Links this Mac to a Windows PC running the Albumscape bridge (windows-bridge/albumscape_bridge.py), over your own
//  network and nowhere else. Each side measures the sound it plays and sends the 48 visualizer levels, about 30 times a
//  second, to the other: music on the PC moves the Mac's bars, and the Mac's sound moves the PC's. Only those 48 numbers
//  travel: no audio, no screen, nothing leaves the local network. Off until it is switched on in Settings.
//
//  A packet is 53 bytes of UDP to port 49733: "ALB1", a type byte (1 = bars), 48 levels (0...255).
//

import Foundation
import Network

@MainActor
final class PeerLink: ObservableObject {
    static let shared = PeerLink()
    static let port: NWEndpoint.Port = 49733
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "linkPC") }

    @Published private(set) var status = "Off"
    private var listener: NWListener?
    private var out: NWConnection?
    private var outHost = ""
    private var learned: String?  // the address the PC's packets came from
    private var received = Date.distantPast

    /// True while the PC has sent bars in the last half second.
    var receiving: Bool { Date().timeIntervalSince(received) < 0.5 }

    func apply() {
        if Self.enabled { start() } else { stop() }
    }

    private func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .udp, on: Self.port)
            l.service = NWListener.Service(name: "Albumscape Lock", type: "_albumscape._udp")
            l.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                Task { @MainActor in self?.receive(on: connection) }
            }
            l.start(queue: .main)
            listener = l
            status = "Waiting for the PC"
            Debug.log("link: listening on port \(Self.port)")
        } catch { status = "Couldn't listen (\(error.localizedDescription))" }
    }

    func stop() {
        listener?.cancel(); listener = nil
        out?.cancel(); out = nil; outHost = ""
        learned = nil
        status = "Off"
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, data.count >= 53, data.prefix(4) == Data("ALB1".utf8), data[4] == 1 {
                    if case let .hostPort(host, _) = connection.endpoint { self.learned = "\(host)".components(separatedBy: "%").first }
                    self.received = Date()
                    self.status = "Receiving from the PC (\(self.learned ?? "?"))"
                    AudioSpectrum.shared.setRemote(data.suffix(48).map { Float($0) / 255 })
                }
                if error == nil { self.receive(on: connection) }
            }
        }
    }

    /// Our own bars, to the PC: the address typed in Settings, or the one its packets came from.
    func send(_ bands: [Float]) {
        guard Self.enabled, listener != nil else { return }
        let typed = (UserDefaults.standard.string(forKey: "pcAddress") ?? "").trimmingCharacters(in: .whitespaces)
        let host = typed.isEmpty ? (learned ?? "") : typed
        guard !host.isEmpty else { return }
        if host != outHost {
            out?.cancel()
            let c = NWConnection(host: NWEndpoint.Host(host), port: Self.port, using: .udp)
            c.start(queue: .main)
            out = c; outHost = host
        }
        var packet = Data("ALB1".utf8) + Data([1])
        packet += Data(bands.prefix(48).map { UInt8(min(255, max(0, $0 * 255))) })
        out?.send(content: packet, completion: .idempotent)
    }
}
