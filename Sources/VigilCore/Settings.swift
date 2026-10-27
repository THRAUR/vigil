import Foundation

public struct Settings: Codable, Equatable, Sendable {
    /// On battery, let the Mac sleep at or below this charge. 0 turns the floor off.
    public var batteryFloor: Int = 20
    /// Only keep awake on external power.
    public var onlyOnAC: Bool = false
    /// Step aside while Low Power Mode is on.
    public var pauseInLowPowerMode: Bool = true
    /// Let the Mac sleep at this thermal state or hotter (`serious` or `critical`).
    public var thermalCutoff: ThermalLevel = .serious
    /// `pmset displaysleepnow` when the lid closes while awake, so the panel doesn't glow in a bag.
    public var displayOffOnLidClose: Bool = true
    /// "Mac mini mode": stay awake whenever plugged in, holds or not.
    public var awakeOnAC: Bool = false
    /// Agent sessions with no hook activity for this long are released.
    public var sessionIdleTimeout: TimeInterval = 2 * 3600
    /// When the last hold ends (or safety cuts in) with the lid closed and no external display,
    /// ask the Mac to sleep instead of waiting for idle sleep, which other apps' assertions can block.
    public var sleepWhenReleasedLidClosed: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        batteryFloor = try c.decodeIfPresent(Int.self, forKey: .batteryFloor) ?? d.batteryFloor
        onlyOnAC = try c.decodeIfPresent(Bool.self, forKey: .onlyOnAC) ?? d.onlyOnAC
        pauseInLowPowerMode = try c.decodeIfPresent(Bool.self, forKey: .pauseInLowPowerMode) ?? d.pauseInLowPowerMode
        thermalCutoff = try c.decodeIfPresent(ThermalLevel.self, forKey: .thermalCutoff) ?? d.thermalCutoff
        displayOffOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .displayOffOnLidClose) ?? d.displayOffOnLidClose
        awakeOnAC = try c.decodeIfPresent(Bool.self, forKey: .awakeOnAC) ?? d.awakeOnAC
        sessionIdleTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .sessionIdleTimeout) ?? d.sessionIdleTimeout
        sleepWhenReleasedLidClosed = try c.decodeIfPresent(Bool.self, forKey: .sleepWhenReleasedLidClosed) ?? d.sleepWhenReleasedLidClosed
    }

    public static let batteryFloorChoices = [0, 10, 15, 20, 25, 30, 40, 50]

    // MARK: `vigil config KEY VALUE`

    public static let keys: [(key: String, help: String)] = [
        ("battery-floor", "percent (0 = off); on battery, sleep at or below it"),
        ("only-on-ac", "on|off; keep awake only when plugged in"),
        ("low-power-pause", "on|off; step aside in Low Power Mode"),
        ("thermal-cutoff", "serious|critical; sleep at this thermal state"),
        ("display-off", "on|off; turn the display off when the lid closes"),
        ("ac-mode", "on|off; always awake while plugged in (Mac mini mode)"),
        ("session-idle", "duration; release agent sessions idle this long"),
        ("lid-sleep", "on|off; sleep right away when holds end with the lid closed"),
    ]

    public func value(for key: String) -> String? {
        switch key {
        case "battery-floor": return batteryFloor == 0 ? "off" : "\(batteryFloor)%"
        case "only-on-ac": return Self.onOff(onlyOnAC)
        case "low-power-pause": return Self.onOff(pauseInLowPowerMode)
        case "thermal-cutoff": return thermalCutoff.label
        case "display-off": return Self.onOff(displayOffOnLidClose)
        case "ac-mode": return Self.onOff(awakeOnAC)
        case "session-idle": return DurationText.format(sessionIdleTimeout)
        case "lid-sleep": return Self.onOff(sleepWhenReleasedLidClosed)
        default: return nil
        }
    }

    public enum ConfigError: Error, Equatable, CustomStringConvertible {
        case unknownKey(String)
        case badValue(key: String, value: String, expected: String)
        public var description: String {
            switch self {
            case .unknownKey(let k): return "unknown setting '\(k)'"
            case .badValue(let k, let v, let e): return "bad value '\(v)' for \(k) (expected \(e))"
            }
        }
    }

    public mutating func set(_ key: String, to raw: String) throws {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        func bool() throws -> Bool {
            switch value {
            case "on", "yes", "true", "1": return true
            case "off", "no", "false", "0": return false
            default: throw ConfigError.badValue(key: key, value: raw, expected: "on|off")
            }
        }
        switch key {
        case "battery-floor":
            let digits = value.hasSuffix("%") ? String(value.dropLast()) : value
            if value == "off" { batteryFloor = 0; return }
            guard let n = Int(digits), (0...90).contains(n) else {
                throw ConfigError.badValue(key: key, value: raw, expected: "0-90 or off")
            }
            batteryFloor = n
        case "only-on-ac": onlyOnAC = try bool()
        case "low-power-pause": pauseInLowPowerMode = try bool()
        case "thermal-cutoff":
            switch value {
            case "serious": thermalCutoff = .serious
            case "critical": thermalCutoff = .critical
            default: throw ConfigError.badValue(key: key, value: raw, expected: "serious|critical")
            }
        case "display-off": displayOffOnLidClose = try bool()
        case "ac-mode": awakeOnAC = try bool()
        case "session-idle":
            guard let t = DurationText.parse(value), t >= 60 else {
                throw ConfigError.badValue(key: key, value: raw, expected: "a duration of at least 1m, e.g. 90m")
            }
            sessionIdleTimeout = t
        case "lid-sleep": sleepWhenReleasedLidClosed = try bool()
        default: throw ConfigError.unknownKey(key)
        }
    }

    private static func onOff(_ b: Bool) -> String { b ? "on" : "off" }
}
