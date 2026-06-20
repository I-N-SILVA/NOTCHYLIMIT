import Foundation
import IOKit.ps

/// Reads the Mac's current power source so the poll loop can ease off when the
/// machine is running on battery or in Low Power Mode. Desktops (no battery)
/// always report AC, so this is a no-op for them.
enum PowerState {
    /// True when the primary power source is the internal battery (not AC).
    static func onBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let state = desc[kIOPSPowerSourceStateKey] as? String
            else { continue }
            if state == kIOPSBatteryPowerValue { return true }
        }
        return false
    }

    /// A multiplier applied to the poll interval to conserve power. 1.0 on AC at
    /// full power; larger when on battery and/or in Low Power Mode. The poll loop
    /// still clamps the final interval to its own min/max.
    static func pollMultiplier() -> TimeInterval {
        var multiplier: TimeInterval = 1
        if ProcessInfo.processInfo.isLowPowerModeEnabled { multiplier *= 2 }
        if onBattery() { multiplier *= 1.5 }
        return multiplier
    }
}
