import Foundation

public enum HoldKind: String, Codable, Sendable, CaseIterable {
    /// Indefinite, until released ("Keep awake").
    case manual
    /// Until `expiresAt` (menu timers, `vigil hold --for`).
    case timed
    /// Until the watched process exits (`vigil hold --pid`, `vigil run`).
    case process
    /// An agent session (Claude Code hooks): until released, its process exits, or it goes idle.
    case session
}

/// One reason to keep the Mac awake. SleepDisabled is on while at least one hold is active.
public struct Hold: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: HoldKind
    public var reason: String
    public var source: String
    public var createdAt: Date
    /// Hard deadline. Required for `.timed`; an optional cap for the other kinds.
    public var expiresAt: Date?
    /// Watched process. The hold is released when it exits.
    public var pid: Int32?
    /// Start time of `pid` (seconds since 1970), to tell a reused pid from the original process.
    public var pidStartTime: Double?
    /// Last sign of life from a session (hook activity).
    public var lastSeen: Date?
    /// Release a session after this long without activity.
    public var idleTimeout: TimeInterval?
    /// A session whose turn ended with this many background tasks/crons still pending. While set,
    /// idle notifications don't release it; the next prompt or tool call clears it.
    public var parkedOnBackground: Int?

    public init(id: String, kind: HoldKind, reason: String, source: String, createdAt: Date,
                expiresAt: Date? = nil, pid: Int32? = nil, pidStartTime: Double? = nil,
                lastSeen: Date? = nil, idleTimeout: TimeInterval? = nil, parkedOnBackground: Int? = nil) {
        self.id = id
        self.kind = kind
        self.reason = reason
        self.source = source
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.pid = pid
        self.pidStartTime = pidStartTime
        self.lastSeen = lastSeen
        self.idleTimeout = idleTimeout
        self.parkedOnBackground = parkedOnBackground
    }

    /// When this hold ends on its own, if ever.
    public var deadline: Date? {
        guard kind == .session, let idle = idleTimeout, idle > 0 else { return expiresAt }
        let idleDeadline = (lastSeen ?? createdAt).addingTimeInterval(idle)
        return expiresAt.map { min($0, idleDeadline) } ?? idleDeadline
    }
}

public enum HoldID {
    public static let manual = "manual"
    public static let menuTimer = "timer"
    public static func session(_ sessionID: String) -> String { "session:" + sessionID }
    public static func process(_ pid: Int32) -> String { "pid-\(pid)" }
    public static func random() -> String {
        "h-" + String(UInt32.random(in: 0x1000...0xFFFF), radix: 16)
    }
}
