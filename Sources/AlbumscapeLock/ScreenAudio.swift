//
//  ScreenAudio.swift
//
//  The second way Droppy hears the Mac's sound: ScreenCaptureKit's audio stream (the same system macOS uses for screen
//  recordings with sound). Only the audio is used; the picture is asked for at the smallest size and thrown away.
//  Needs "Screen & System Audio Recording" permission. The audio is measured, never recorded or stored.
//

import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class ScreenAudio: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "albumscape.screenaudio", qos: .userInteractive)
    private let processor: SpectrumProcessor

    init(processor: SpectrumProcessor) { self.processor = processor }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw NSError(domain: "ScreenAudio", code: 1) }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2; config.height = 2  // the picture isn't wanted
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        processor.sampleRate = 48_000
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        try? sampleBuffer.withAudioBufferList { list, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(list.unsafeMutablePointer)
            guard let first = buffers.first, let firstData = first.mData else { return }
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / max(Int(first.mNumberChannels), 1)
            if buffers.count > 1, first.mNumberChannels == 1 {
                // planar: one buffer per channel; average them
                var mono = [Float](repeating: 0, count: frames)
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let p = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<frames { mono[i] += p[i] / Float(buffers.count) }
                }
                mono.withUnsafeBufferPointer { processor.feed($0, channels: 1) }
            } else {
                processor.feed(UnsafeBufferPointer(start: firstData.assumingMemoryBound(to: Float.self), count: frames * Int(first.mNumberChannels)), channels: max(Int(first.mNumberChannels), 1))
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { Debug.log("spectrum: the audio stream stopped: \(error.localizedDescription)") }
}
