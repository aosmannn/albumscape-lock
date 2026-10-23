import Foundation
import IOKit.ps

/// Battery saver: on a laptop running down, the heavy things (music videos, the visualizer, the animated desktop) stop
/// and the still or animated cover stays. Settings picks when: never, below 20 %, below 40 %, or whenever unplugged.
enum Power {
    /// 0 = never, otherwise the charge (percent) below which it saves; 100 = whenever on battery.
    static var threshold: Int { UserDefaults.standard.object(forKey: "batterySaver") as? Int ?? 20 }

    static var onBattery: (percent: Int, unplugged: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let now = d[kIOPSCurrentCapacityKey] as? Int ?? 100, max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            return (max > 0 ? now * 100 / max : now, d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue)
        }
        return nil  // a desktop Mac
    }

    static var saving: Bool {
        let limit = threshold
        guard limit > 0, let battery = onBattery, battery.unplugged else { return false }
        return limit >= 100 || battery.percent < limit
    }
}
