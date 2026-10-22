//
//  KeyWatcher.swift
//
//  The L, N and right-arrow keys. The lock screen sends typing to its password box, so a normal key handler never hears it; this reads
//  the keyboard at the HID level instead (macOS asks once for Input Monitoring). Only those keys are looked at: no other
//  key is read, kept or logged.
//

import Foundation
import IOKit.hid

final class KeyWatcher {
    private var manager: IOHIDManager?
    /// Called with the key's HID usage: 0x0F is L, 0x11 is N, 0x4F is the right arrow.
    private let onKey: (UInt32) -> Void

    init(onKey: @escaping (UInt32) -> Void) { self.onKey = onKey }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad), IOHIDValueGetIntegerValue(value) == 1, let context else { return }
            let usage = IOHIDElementGetUsage(element)
            guard usage == UInt32(kHIDUsage_KeyboardL) || usage == UInt32(kHIDUsage_KeyboardN) || usage == UInt32(kHIDUsage_KeyboardRightArrow) else { return }
            let watcher = Unmanaged<KeyWatcher>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { watcher.onKey(usage) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        Debug.log("key watcher: \(result == kIOReturnSuccess ? "listening" : "not allowed (\(result)): turn on Albumscape Lock in Privacy & Security > Input Monitoring")")
        self.manager = manager
    }
}
