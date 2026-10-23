//
//  AudioSpectrum.swift
//
//  A real audio visualizer, the way Droppy and Apple's players do it: the sound the Mac is actually playing is read
//  through a Core Audio "tap" (macOS asks once for System Audio permission; the screen is never captured), split into frequency bands with an FFT
//  (Accelerate), smoothed, and drawn. Nothing is made up: silence draws flat bars. The audio is never recorded or stored,
//  only measured, and only while the player is on screen.
//

import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import SwiftUI

/// The measuring, off the main thread.
final class SpectrumProcessor: @unchecked Sendable {
    static let bandCount = 48
    private let fftSize = 4096  // 12 Hz per bin: enough to tell the bass notes apart
    private let log2n: vDSP_Length = 12
    private let setup: FFTSetup
    private var window: [Float]
    private var ring: [Float] = []
    private var smoothed = [Float](repeating: 0, count: SpectrumProcessor.bandCount)
    private let lock = NSLock()
    private var latest = [Float](repeating: 0, count: SpectrumProcessor.bandCount)
    var sampleRate: Float = 48_000
    /// For the log: how many buffers arrived, and the loudest sample, since the last report.
    private(set) var blocks = 0
    private(set) var peak: Float = 0
    private(set) var channelsSeen = 0
    func takeReport() -> (blocks: Int, peak: Float, channels: Int) { lock.lock(); defer { lock.unlock(); blocks = 0; peak = 0 }; return (blocks, peak, channelsSeen) }

    init() {
        setup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: 4096)
        vDSP_hann_window(&window, 4096, Int32(vDSP_HANN_NORM))
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    func snapshot() -> [Float] { lock.lock(); defer { lock.unlock() }; return latest }

    func reset() { lock.lock(); latest = [Float](repeating: 0, count: Self.bandCount); lock.unlock(); smoothed = latest; ring.removeAll() }

    /// Mono samples in; whenever a window of 4096 is ready, the bands are updated.
    func feed(_ samples: UnsafeBufferPointer<Float>, channels: Int) {
        let frames = samples.count / max(channels, 1)
        lock.lock(); blocks += 1; channelsSeen = channels; for v in samples { peak = max(peak, abs(v)) }; lock.unlock()
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += samples[f * channels + c] }
            ring.append(sum / Float(channels))
        }
        while ring.count >= fftSize { process(Array(ring.prefix(fftSize))); ring.removeFirst(fftSize / 4) }  // new measurement every 1024 samples (75% overlap)
    }

    private func process(_ block: [Float]) {
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(block, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        var real = [Float](repeating: 0, count: fftSize / 2), imag = [Float](repeating: 0, count: fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2)) }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }
        // log-spaced bands from 40 Hz to 14 kHz, the way ears (and Apple's visualizers) group sound
        let binHz = sampleRate / Float(fftSize)
        let low: Float = 40, high = min(14_000, sampleRate / 2 - 1)
        var bands = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let f0 = low * powf(high / low, Float(b) / Float(Self.bandCount))
            let f1 = low * powf(high / low, Float(b + 1) / Float(Self.bandCount))
            let i0 = max(1, Int(f0 / binHz)), i1 = min(fftSize / 2 - 1, max(i0 + 1, Int(f1 / binHz)))
            var peak: Float = 0
            for i in i0..<i1 { peak = max(peak, magnitudes[i]) }
            let db = 10 * log10f(max(peak, 1e-12) / Float(fftSize * fftSize) * 4)
            // louder highs are quieter in music: tilt the upper bands up a little so the whole range moves
            let tilt = 5.0 * Float(b) / Float(Self.bandCount)
            bands[b] = min(1, max(0, (db + 78 + tilt) / 56))
        }
        for b in 0..<Self.bandCount {  // quick to rise, slower to fall
            smoothed[b] = bands[b] > smoothed[b] ? smoothed[b] + (bands[b] - smoothed[b]) * 0.7 : smoothed[b] + (bands[b] - smoothed[b]) * 0.22
        }
        lock.lock(); latest = smoothed; lock.unlock()
    }
}

@MainActor
final class AudioSpectrum: ObservableObject {
    static let shared = AudioSpectrum()
    @Published private(set) var bands = [Float](repeating: 0, count: SpectrumProcessor.bandCount)
    @Published private(set) var running = false

    /// On by default; Settings turns it off.
    static var enabled: Bool { UserDefaults.standard.object(forKey: "audioVisualizer") as? Bool != false }

    private let processor = SpectrumProcessor()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "albumscape.spectrum", qos: .userInteractive)

    /// While this time is in the future the visualizer keeps listening even when the player isn't on screen (for the
    /// Allow button and the self-test).
    var holdUntil = Date.distantPast

    /// Listens to the Mac's sound through a Core Audio tap: audio only, never the screen. macOS shows its audio indicator
    /// (the small purple dot) while this runs.
    func start() {
        guard !running else { return }
        startTap()
    }

    private func beginReporting(source: String) {
        var ticks = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bands = self.processor.snapshot()
                ticks += 1
                if ticks % 90 == 0 { let r = self.processor.takeReport(); let b = self.bands, g = b.count / 6
                    let groups = (0..<6).map { String(format: "%.2f", b[($0 * g)..<(($0 + 1) * g)].max() ?? 0) }.joined(separator: " ")
                    Debug.log("spectrum (\(source)): \(r.blocks) buffers in 3 s, loudest sample \(String(format: "%.3f", r.peak)), \(r.channels) channel(s), \(Int(self.processor.sampleRate)) Hz, bars bass>treble: \(groups)") }
            }
        }
        Debug.log("spectrum: listening to the system audio (\(source))")
    }

    private func startTap() {
        guard !running, #available(macOS 14.2, *) else { return }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Albumscape Lock"
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { Debug.log("spectrum: couldn't tap the audio"); return }
        tapID = tap

        // the default output device is the aggregate's clock
        var outputID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &outputID)
        var uidRef: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(outputID, &uidAddress, 0, nil, &uidSize, &uidRef) == noErr, let outputUID = uidRef?.takeRetainedValue() as String? else { stop(); return }

        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Albumscape Lock tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregate) == noErr else { stop(); return }
        aggregateID = aggregate

        // the tap's own format (rate and channels)
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &format) == noErr, format.mSampleRate > 0 { processor.sampleRate = Float(format.mSampleRate) }

        let processor = self.processor
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                processor.feed(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count), channels: max(Int(buffer.mNumberChannels), 1))
            }
        }
        guard status == noErr, let proc else { stop(); return }
        procID = proc
        guard AudioDeviceStart(aggregate, proc) == noErr else { stop(); return }
        running = true
        beginReporting(source: "audio tap")
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let procID, aggregateID != kAudioObjectUnknown { AudioDeviceStop(aggregateID, procID); AudioDeviceDestroyIOProcID(aggregateID, procID) }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = AudioObjectID(kAudioObjectUnknown) }
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        processor.reset()
        bands = [Float](repeating: 0, count: SpectrumProcessor.bandCount)
        if running { Debug.log("spectrum: stopped") }
        running = false
    }

    /// Settings > Allow: listens for a few seconds, so macOS asks for System Audio permission now, on the desktop.
    func requestAccess() {
        holdUntil = Date().addingTimeInterval(6)
        start()
    }
}

/// The bars, drawn the way Droppy draws its visualizer: round-capped bars standing on the middle line, each one band of the
/// real audio, filled with a gradient of the song's colour (lighter at the tips), growing from a dot when quiet.
struct SpectrumBars: View {
    @ObservedObject private var spectrum = AudioSpectrum.shared
    let accent: Color
    var count = 7
    var barWidth: CGFloat = 3.5
    var spacing: CGFloat = 3
    /// Only for pictures of the design: levels (0...1) to draw instead of the live audio.
    var levels: [Float]?

    var body: some View {
        Canvas { context, size in
            let bands = levels ?? spectrum.bands
            let n = max(count, 1)
            let total = CGFloat(n) * barWidth + CGFloat(n - 1) * spacing
            let startX = (size.width - total) / 2
            let light = Color.white.opacity(0.55)
            for i in 0..<n {
                // each bar takes a slice of the bands (the low end gets its own bars; the top is shared)
                let from = i * bands.count / n, to = max(from + 1, (i + 1) * bands.count / n)
                let level = CGFloat(bands[from..<to].max() ?? 0)
                let height = max(barWidth, pow(level, 0.85) * size.height)
                let rect = CGRect(x: startX + CGFloat(i) * (barWidth + spacing), y: (size.height - height) / 2, width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .linearGradient(Gradient(colors: [accent.mix(with: light), accent]),
                                                   startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
            }
        }
        .shadow(color: accent.opacity(0.35), radius: 3)
        .allowsHitTesting(false)
    }
}

private extension Color {
    /// A simple blend toward another colour, for the lit tips of the bars.
    func mix(with other: Color) -> Color { Color(nsColor: (NSColor(self).blended(withFraction: 0.45, of: NSColor(other)) ?? NSColor(self))) }
}
