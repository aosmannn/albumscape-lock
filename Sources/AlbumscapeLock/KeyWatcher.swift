//
//  KeyWatcher.swift
//
//  The L key. The lock screen sends typing to its password box, so a normal key handler never hears it; this reads
//  the keyboard at the HID level instead (macOS asks once for Input Monitoring). Only the L key is looked at: no other
//  key is read, kept or logged.
//

import Foundation
import IOKit.hid

final class KeyWatcher {
    private var manager: IOHIDManager?
    private let onL: () -> Void

    init(onL: @escaping () -> Void) { self.onL = onL }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad),
                  IOHIDElementGetUsage(element) == UInt32(kHIDUsage_KeyboardL),
                  IOHIDValueGetIntegerValue(value) == 1, let context else { return }
            Debug.log("L pressed")
            let watcher = Unmanaged<KeyWatcher>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { watcher.onL() }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        Debug.log("L key watcher: \(result == kIOReturnSuccess ? "listening" : "not allowed (\(result)): turn on Albumscape Lock in Privacy & Security > Input Monitoring")")
        self.manager = manager
    }
}
