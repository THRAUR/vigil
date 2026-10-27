import Foundation

/// Written by the app every 30 s (and whenever it is about to change the flag). The time is
/// CLOCK_UPTIME_RAW, which stops while the Mac sleeps, so a nap never looks like a hang.
public struct Heartbeat: Codable, Equatable, Sendable {
    public var pid: Int32
    public var pidStartTime: Double
    public var uptimeNanos: UInt64
    public var bootSession: String
    public var wall: Date
    /// False once the app has shut down cleanly.
    public var running: Bool
    public var wantsAwake: Bool

    public init(pid: Int32, pidStartTime: Double, uptimeNanos: UInt64, bootSession: String,
                wall: Date, running: Bool, wantsAwake: Bool) {
        self.pid = pid
        self.pidStartTime = pidStartTime
        self.uptimeNanos = uptimeNanos
        self.bootSession = bootSession
        self.wall = wall
        self.running = running
        self.wantsAwake = wantsAwake
    }
}

public enum WatchdogVerdict: Equatable, Sendable {
    case healthy
    case noHeartbeat
    case otherBoot
    case stopped
    case dead
    case hung(seconds: Double)

    /// Reads after "the app": "the app died", "the app is unresponsive (91 s without a heartbeat)".
    public var label: String {
        switch self {
        case .healthy: return "is healthy"
        case .noHeartbeat: return "never ran"
        case .otherBoot: return "hasn't run since boot"
        case .stopped: return "quit"
        case .dead: return "died"
        case .hung(let s): return "is unresponsive (\(Int(s)) s without a heartbeat)"
        }
    }
}

public enum WatchdogLogic {
    public static let staleAfter: TimeInterval = 90
    /// Longest the watchdog sleeps between checks while the app looks healthy.
    public static let maxInterval: TimeInterval = 60

    public static func verdict(_ hb: Heartbeat?, nowUptimeNanos: UInt64, bootSession: String,
                               isAlive: (Int32, Double) -> Bool) -> WatchdogVerdict {
        guard let hb else { return .noHeartbeat }
        guard hb.bootSession == bootSession else { return .otherBoot }
        guard hb.running else { return .stopped }
        guard isAlive(hb.pid, hb.pidStartTime) else { return .dead }
        let age = ageSeconds(hb, nowUptimeNanos: nowUptimeNanos)
        return age > staleAfter ? .hung(seconds: age) : .healthy
    }

    public static func ageSeconds(_ hb: Heartbeat, nowUptimeNanos: UInt64) -> Double {
        nowUptimeNanos > hb.uptimeNanos ? Double(nowUptimeNanos - hb.uptimeNanos) / 1e9 : 0
    }

    /// The flag must be cleared whenever it is on and the app can't vouch for it.
    public static func mustClear(_ verdict: WatchdogVerdict, flagOn: Bool) -> Bool {
        flagOn && verdict != .healthy
    }

    /// Next check: right when the current heartbeat would go stale, but at least every `maxInterval`.
    public static func nextCheckDelay(_ verdict: WatchdogVerdict, _ hb: Heartbeat?, nowUptimeNanos: UInt64) -> TimeInterval {
        guard verdict == .healthy, let hb else { return maxInterval }
        let untilStale = staleAfter - ageSeconds(hb, nowUptimeNanos: nowUptimeNanos) + 1
        return min(maxInterval, max(1, untilStale))
    }
}

/// Left by the watchdog when it clears the flag, so the app (if it was only hung) knows the
/// reset wasn't the user's and can re-assert its holds.
public struct WatchdogMark: Codable, Equatable, Sendable {
    public var at: Date
    public var appPID: Int32
    public var verdict: String

    public init(at: Date, appPID: Int32, verdict: String) {
        self.at = at
        self.appPID = appPID
        self.verdict = verdict
    }
}
