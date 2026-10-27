import Foundation

/// Why a hold went away. Only `.user` releases are remembered for sessions (see `acquireSession`).
public enum ReleaseCause: String, Codable, Sendable {
    case user, agent, expired, processExited
}

/// What started an agent acquire.
public enum AcquireTrigger: String, Codable, Sendable {
    /// A new user prompt (UserPromptSubmit), or an explicit `vigil acquire --session`.
    case prompt
    /// Background activity inside a turn (PreToolUse). Refreshes, and re-creates a hold the agent
    /// itself released, but never one the user released.
    case activity
    /// Refresh an existing hold only (subagent activity).
    case refresh
}

public enum AcquireOutcome: String, Codable, Sendable {
    case created, refreshed, suppressed
}

/// The set of active holds, keyed by id. Acquiring an id that exists refreshes it, so the
/// refcount is the number of distinct holds: the flag stays on until the last one is gone.
public struct HoldBook: Codable, Equatable, Sendable {
    public private(set) var holds: [String: Hold] = [:]
    /// Sessions the user released by hand (menu, "Let it sleep", an external `pmset` reset),
    /// so tool activity in a running turn doesn't silently grab the Mac again.
    public private(set) var userReleasedSessions: [String: Date] = [:]

    public init() {}

    public var isEmpty: Bool { holds.isEmpty }
    public var count: Int { holds.count }
    public subscript(id: String) -> Hold? { holds[id] }

    /// Oldest first, which is the order the menu and `vigil status` show.
    public var sorted: [Hold] {
        holds.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// Adds a hold, or replaces the one with the same id (keeping its creation time).
    /// Returns true if it is new.
    @discardableResult
    public mutating func upsert(_ hold: Hold) -> Bool {
        var hold = hold
        let old = holds[hold.id]
        if let old { hold.createdAt = old.createdAt }
        holds[hold.id] = hold
        if hold.kind == .session, let sid = Self.sessionID(fromHoldID: hold.id) {
            userReleasedSessions[sid] = nil
        }
        return old == nil
    }

    public mutating func acquireSession(_ sessionID: String, trigger: AcquireTrigger, reason: String,
                                        source: String, pid: Int32?, pidStartTime: Double?,
                                        idleTimeout: TimeInterval, now: Date) -> AcquireOutcome {
        let key = HoldID.session(sessionID)
        if var existing = holds[key] {
            existing.lastSeen = now
            existing.idleTimeout = idleTimeout
            if trigger != .refresh { existing.parkedOnBackground = nil }
            if !reason.isEmpty { existing.reason = reason }
            if let pid {
                existing.pid = pid
                existing.pidStartTime = pidStartTime
            }
            holds[key] = existing
            return .refreshed
        }
        if trigger == .refresh { return .suppressed }
        if trigger == .activity, userReleasedSessions[sessionID] != nil { return .suppressed }
        userReleasedSessions[sessionID] = nil
        holds[key] = Hold(id: key, kind: .session, reason: reason, source: source, createdAt: now,
                          pid: pid, pidStartTime: pidStartTime, lastSeen: now, idleTimeout: idleTimeout)
        return .created
    }

    @discardableResult
    public mutating func release(id: String, cause: ReleaseCause, now: Date) -> Hold? {
        guard let hold = holds.removeValue(forKey: id) else { return nil }
        noteRelease(hold, cause: cause, now: now)
        return hold
    }

    /// Releases a session's hold. A `soft` release (idle notification) leaves a parked session alone.
    @discardableResult
    public mutating func releaseSession(_ sessionID: String, cause: ReleaseCause, soft: Bool = false, now: Date) -> Hold? {
        let key = HoldID.session(sessionID)
        if soft, let parked = holds[key]?.parkedOnBackground, parked > 0 { return nil }
        return release(id: key, cause: cause, now: now)
    }

    /// A turn ended with background work pending: keep the session's hold (refreshing its idle
    /// clock) until that work reports back in a new turn. Returns false if there was no hold.
    @discardableResult
    public mutating func parkSession(_ sessionID: String, pending: Int, now: Date) -> Bool {
        let key = HoldID.session(sessionID)
        guard var hold = holds[key] else { return false }
        hold.parkedOnBackground = pending
        hold.lastSeen = now
        holds[key] = hold
        return true
    }

    @discardableResult
    public mutating func releaseAll(cause: ReleaseCause, now: Date) -> [Hold] {
        let gone = sorted
        holds.removeAll()
        for hold in gone { noteRelease(hold, cause: cause, now: now) }
        return gone
    }

    /// Releases every hold bound to a process that exited.
    @discardableResult
    public mutating func releaseProcess(pid: Int32, now: Date) -> [Hold] {
        let gone = sorted.filter { $0.pid == pid }
        for hold in gone { holds[hold.id] = nil }
        return gone
    }

    /// Removes holds whose deadline has passed and returns them.
    @discardableResult
    public mutating func expire(now: Date) -> [Hold] {
        let gone = sorted.filter { ($0.deadline.map { $0 <= now }) ?? false }
        for hold in gone { holds[hold.id] = nil }
        pruneUserReleases(now: now)
        return gone
    }

    public func nextDeadline() -> Date? {
        holds.values.compactMap(\.deadline).min()
    }

    public var watchedPIDs: Set<Int32> { Set(holds.values.compactMap(\.pid)) }

    private mutating func noteRelease(_ hold: Hold, cause: ReleaseCause, now: Date) {
        guard cause == .user, hold.kind == .session, let sid = Self.sessionID(fromHoldID: hold.id) else { return }
        userReleasedSessions[sid] = now
    }

    private mutating func pruneUserReleases(now: Date) {
        userReleasedSessions = userReleasedSessions.filter { now.timeIntervalSince($0.value) < 12 * 3600 }
    }

    static func sessionID(fromHoldID id: String) -> String? {
        id.hasPrefix("session:") ? String(id.dropFirst("session:".count)) : nil
    }
}
