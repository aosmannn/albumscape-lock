//
//  AudioOutputs.swift
//
//  The speakers and headphones the Mac can play through, and switching between them (the same thing as choosing an
//  output in the menu bar's sound menu). Spotify and Music follow the Mac's output.
//

import CoreAudio
import Foundation

struct OutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let isCurrent: Bool
    let symbol: String   // laptop speakers, headphones, a display...
    var volume: Float?   // 0...1, when the device has one
}

enum AudioOutputs {
    static func list() -> [OutputDevice] {
        let current = defaultOutput()
        return allDevices().filter(hasOutput).filter { !isOurTap($0) }.map { OutputDevice(id: $0, name: name(of: $0), isCurrent: $0 == current, symbol: symbol(of: $0), volume: volume(of: $0)) }
    }

    /// The visualizer's own listening device ("Albumscape Lock tap"): it isn't somewhere to play sound, so it's never listed.
    private static func isOurTap(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &type)
        return type == kAudioDeviceTransportTypeAggregate || name(of: device).hasPrefix("Albumscape Lock")
    }

    /// The device's main volume, the same control as the sound menu's slider.
    static func volume(of device: AudioDeviceID) -> Float? {
        var address = AudioObjectPropertyAddress(mSelector: 0x766D_7663 /* 'vmvc' */, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func setVolume(_ value: Float, of device: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(mSelector: 0x766D_7663, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var v = Float32(min(1, max(0, value)))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    private static func symbol(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &type)
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return bluetoothSymbol(of: device)
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker"
        default: return "speaker.wave.2"
        }
    }

    /// What Bluetooth audio this is: Core Audio's model id for it is the Bluetooth "product vendor" pair in hex
    /// ("201b 4c": Apple), which tells AirPods (and which kind) from other headphones whatever the owner named them.
    private static func bluetoothSymbol(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyModelUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var model: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &model) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        let parts = (status == noErr ? (model as String? ?? "") : "").split(separator: " ").compactMap { Int($0, radix: 16) }
        if parts.count >= 2, parts[1] == 0x4C {  // Apple
            switch parts[0] {
            case 0x200A: return "airpodsmax"
            case 0x200E, 0x2014, 0x2024, 0x2027: return "airpodspro"
            case 0x2006, 0x2009, 0x200B, 0x2010, 0x2011, 0x2012, 0x2016, 0x2017: return "headphones"  // Beats
            default: return "airpods"
            }
        }
        return "headphones"
    }

    /// The icon of the output that is playing now, for the button on the player.
    static func currentSymbol() -> String {
        guard let device = allDevices().first(where: { $0 == defaultOutput() }) else { return "speaker.wave.2" }
        return symbol(of: device)
    }

    @discardableResult
    static func select(_ id: AudioDeviceID) -> Bool {
        var device = id
        var ok = true
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &device)
            if status != noErr { ok = false; Debug.log("audio output: couldn't switch (\(status))") }
        }
        return ok
    }

    private static func defaultOutput() -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func hasOutput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func name(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return "Output" }
        return name.takeRetainedValue() as String
    }
}
