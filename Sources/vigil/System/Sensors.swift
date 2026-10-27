import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import VigilCore

/// Battery and AC state, pushed by IOKit's power-source notifications (no polling).
final class PowerMonitor {
    private var source: CFRunLoopSource?
    private let onChange: (PowerSnapshot) -> Void

    init(onChange: @escaping (PowerSnapshot) -> Void) {
        self.onChange = onChange
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.onChange(PowerMonitor.read())
        }, context)?.takeRetainedValue() else {
            Log.warn("couldn't subscribe to power-source notifications")
            return
        }
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    }

    static func read() -> PowerSnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unknown
        }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        var snapshot = PowerSnapshot(onAC: providing != kIOPSBatteryPowerValue, hasBattery: false, batteryPercent: nil, isCharging: false)
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            snapshot.hasBattery = true
            if let cur = desc[kIOPSCurrentCapacityKey] as? Int, let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                snapshot.batteryPercent = Int((Double(cur) / Double(max) * 100).rounded())
            }
            snapshot.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                snapshot.onAC = state == kIOPSACPowerValue
            }
        }
        return snapshot
    }
}

/// Lid open/closed, from IOPMrootDomain's clamshell interest notifications.
final class LidMonitor {
    /// kIOPMMessageClamshellStateChange = iokit_family_msg(sub_iokit_powermanagement, 0x100)
    static let clamshellMessage: UInt32 = 0xE003_4100
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    deinit {
        if notifier != 0 { IOObjectRelease(notifier) }
        if let port { IONotificationPortDestroy(port) }
    }

    func start() {
        let root = FlagIO.rootDomain()
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Log.warn("couldn't watch the lid (no IOPMrootDomain)")
            return
        }
        defer { IOObjectRelease(root) }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let kr = IOServiceAddInterestNotification(port, root, "IOGeneralInterest", { context, _, messageType, _ in
            guard let context, messageType == LidMonitor.clamshellMessage else { return }
            let monitor = Unmanaged<LidMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.onChange(LidMonitor.isClosed())
        }, context, &notifier)
        if kr != KERN_SUCCESS { Log.warn("couldn't watch the lid (IOKit error \(kr))") }
    }

    static func isClosed() -> Bool { FlagIO.rootDomainBool("AppleClamshellState") ?? false }
}

enum Displays {
    /// An active non-built-in display means the Mac is in clamshell mode on purpose.
    static func hasExternal() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}

extension ThermalLevel {
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }
}
