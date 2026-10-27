import Foundation

/// The JSON Claude Code writes to a hook's stdin. Parsed leniently: unknown or missing fields are fine.
public struct HookInput: Equatable, Sendable {
    public var sessionID: String?
    public var event: String?
    public var cwd: String?
    public var notificationType: String?
    /// Set when the hook fires inside a subagent.
    public var agentID: String?
    /// Stop: background tasks still running and session crons still scheduled.
    public var pendingBackgroundWork: Int

    public init(sessionID: String? = nil, event: String? = nil, cwd: String? = nil,
                notificationType: String? = nil, agentID: String? = nil, pendingBackgroundWork: Int = 0) {
        self.sessionID = sessionID
        self.event = event
        self.cwd = cwd
        self.notificationType = notificationType
        self.agentID = agentID
        self.pendingBackgroundWork = pendingBackgroundWork
    }

    public static func parse(_ data: Data) -> HookInput? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            (obj[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return HookInput(sessionID: string("session_id"),
                         event: string("hook_event_name"),
                         cwd: string("cwd"),
                         notificationType: string("notification_type"),
                         agentID: string("agent_id"),
                         pendingBackgroundWork: count(obj["background_tasks"]) + count(obj["session_crons"]))
    }

    /// For inputs too big to parse whole (a PreToolUse carrying a large file): pick out the top-level
    /// string fields. Claude Code writes those first, before tool_input.
    public static func scan(_ data: Data) -> HookInput? {
        let text = String(decoding: data.prefix(1 << 16), as: UTF8.self)
        func field(_ key: String) -> String? {
            guard let r = text.range(of: "\"\(key)\"") else { return nil }
            var i = r.upperBound
            while i < text.endIndex, text[i] == ":" || text[i].isWhitespace { i = text.index(after: i) }
            guard i < text.endIndex, text[i] == "\"" else { return nil }
            var j = text.index(after: i)
            var escaped = false
            while j < text.endIndex {
                let c = text[j]
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { break }
                j = text.index(after: j)
            }
            guard j < text.endIndex else { return nil }
            return (try? JSONParser.parse(String(text[i...j])))?.stringValue
        }
        guard let sid = field("session_id") else { return nil }
        return HookInput(sessionID: sid, event: field("hook_event_name"), cwd: field("cwd"),
                         notificationType: field("notification_type"), agentID: field("agent_id"))
    }

    /// Counts "how much" of a field there is, whatever shape it comes in.
    static func count(_ value: Any?) -> Int {
        switch value {
        case let a as [Any]: return a.count
        case let d as [String: Any]: return d.count
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): return max(0, n.intValue)
        case let b as Bool: return b ? 1 : 0
        default: return 0
        }
    }

    /// "Claude · Blender" from the session's working directory.
    public var holdReason: String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? "Claude Code" : "Claude · " + name
    }
}

/// What a hook event means for the session's hold.
public enum HookAction: Equatable, Sendable {
    case acquire(AcquireTrigger)
    /// Turn finished with background work left: keep holding until that work reports back.
    case park(pending: Int)
    /// `soft` releases are skipped while a session is parked on background work.
    case release(soft: Bool)
    case ignore
}

public enum HookPolicy {
    /// Notification types that mean nobody is driving the session right now.
    public static let idleNotifications: Set<String> = ["idle_prompt", "permission_prompt"]

    public static func action(for input: HookInput) -> HookAction {
        switch input.event {
        case "UserPromptSubmit":
            return .acquire(.prompt)
        case "PreToolUse", "PostToolUse":
            // Subagents may report their own session id; let them refresh but never create a hold
            // that no Stop would ever release.
            return input.agentID == nil ? .acquire(.activity) : .acquire(.refresh)
        case "Stop":
            return input.pendingBackgroundWork > 0 ? .park(pending: input.pendingBackgroundWork) : .release(soft: false)
        case "StopFailure", "SessionEnd":
            return .release(soft: false)
        case "Notification":
            guard let type = input.notificationType else { return .release(soft: true) }
            return idleNotifications.contains(type) ? .release(soft: true) : .ignore
        default:
            return .ignore
        }
    }
}
