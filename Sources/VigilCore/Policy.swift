import Foundation

/// Mirrors ProcessInfo.ThermalState.
public enum ThermalLevel: Int, Codable, Sendable, Comparable, CaseIterable {
    case nominal = 0, fair, serious, critical

    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        }
    }
}

public struct PowerSnapshot: Codable, Equatable, Sendable {
    public var onAC: Bool
    public var hasBattery: Bool
    public var batteryPercent: Int?
    public var isCharging: Bool

    public init(onAC: Bool, hasBattery: Bool, batteryPercent: Int?, isCharging: Bool) {
        self.onAC = onAC
        self.hasBattery = hasBattery
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
    }

    public var onBattery: Bool { hasBattery && !onAC }
    public static let unknown = PowerSnapshot(onAC: true, hasBattery: false, batteryPercent: nil, isCharging: false)
}

/// Everything the safety rules look at.
public struct Conditions: Codable, Equatable, Sendable {
    public var power: PowerSnapshot
    public var thermal: ThermalLevel
    public var lowPowerMode: Bool
    public var lidClosed: Bool

    public init(power: PowerSnapshot, thermal: ThermalLevel, lowPowerMode: Bool, lidClosed: Bool) {
        self.power = power
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
        self.lidClosed = lidClosed
    }
}

/// A safety rule currently forcing the flag off even though something wants the Mac awake.
public enum Inhibitor: String, Codable, Sendable, CaseIterable {
    case thermal, batteryFloor, notOnAC, lowPowerMode

    public var label: String {
        switch self {
        case .thermal: return "too hot"
        case .batteryFloor: return "battery at floor"
        case .notOnAC: return "not plugged in"
        case .lowPowerMode: return "Low Power Mode"
        }
    }
}

/// Safety rules with hysteresis, so a reading that hovers at a threshold doesn't flap the flag.
public struct SafetyGate: Codable, Equatable, Sendable {
    /// Stay tripped until the thermal state has been below the cutoff this long.
    public static let thermalCooldown: TimeInterval = 120
    /// Points above the floor the battery must climb (while on battery) to untrip.
    public static let batteryHysteresis = 2

    public private(set) var thermalTripped = false
    public private(set) var coolingSince: Date?
    public private(set) var batteryTripped = false

    public init() {}

    /// Returns the active inhibitors, and when the gate should be evaluated again (cooldown end).
    public mutating func evaluate(_ c: Conditions, _ s: Settings, now: Date) -> (inhibitors: [Inhibitor], recheckAt: Date?) {
        var inhibitors: [Inhibitor] = []
        var recheckAt: Date?

        if c.thermal >= s.thermalCutoff {
            thermalTripped = true
            coolingSince = nil
        } else if thermalTripped {
            let since = coolingSince ?? now
            if now.timeIntervalSince(since) >= Self.thermalCooldown {
                thermalTripped = false
                coolingSince = nil
            } else {
                coolingSince = since
                recheckAt = since.addingTimeInterval(Self.thermalCooldown)
            }
        }
        if thermalTripped { inhibitors.append(.thermal) }

        if s.batteryFloor <= 0 || !c.power.onBattery {
            batteryTripped = false
        } else if let pct = c.power.batteryPercent {
            if pct <= s.batteryFloor {
                batteryTripped = true
            } else if pct >= s.batteryFloor + Self.batteryHysteresis {
                batteryTripped = false
            }
        }
        if batteryTripped { inhibitors.append(.batteryFloor) }

        if s.onlyOnAC, c.power.onBattery { inhibitors.append(.notOnAC) }
        if s.pauseInLowPowerMode, c.lowPowerMode { inhibitors.append(.lowPowerMode) }
        return (inhibitors, recheckAt)
    }
}

public struct Decision: Codable, Equatable, Sendable {
    /// Something wants the Mac awake (a hold, or Mac mini mode on AC).
    public var demanded: Bool
    public var inhibitors: [Inhibitor]
    /// The flag value Vigil should enforce.
    public var wantAwake: Bool { demanded && inhibitors.isEmpty }
    /// When to evaluate again even if nothing else happens (a hold deadline or a cooldown end).
    public var nextCheck: Date?

    public init(demanded: Bool, inhibitors: [Inhibitor], nextCheck: Date?) {
        self.demanded = demanded
        self.inhibitors = inhibitors
        self.nextCheck = nextCheck
    }

    public static let idle = Decision(demanded: false, inhibitors: [], nextCheck: nil)
}

public enum Policy {
    /// Expires holds, applies the safety gate, and decides the flag. Pure apart from its inout state.
    public static func evaluate(book: inout HoldBook, gate: inout SafetyGate, conditions: Conditions,
                                settings: Settings, now: Date) -> (decision: Decision, expired: [Hold]) {
        let expired = book.expire(now: now)
        let safety = gate.evaluate(conditions, settings, now: now)
        let demanded = !book.isEmpty || (settings.awakeOnAC && conditions.power.onAC)
        let next = [book.nextDeadline(), safety.recheckAt].compactMap { $0 }.min()
        return (Decision(demanded: demanded, inhibitors: safety.inhibitors, nextCheck: next), expired)
    }
}
