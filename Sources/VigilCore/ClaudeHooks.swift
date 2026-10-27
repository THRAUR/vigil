import Foundation

public struct HookSpec: Equatable, Sendable {
    public var event: String
    public var matcher: String?
    public var arguments: String

    public init(event: String, matcher: String?, arguments: String) {
        self.event = event
        self.matcher = matcher
        self.arguments = arguments
    }
}

/// Adds and removes Vigil's entries in ~/.claude/settings.json without disturbing anything else.
public enum ClaudeHooks {
    public static let timeoutSeconds = 10

    public static let specs: [HookSpec] = [
        HookSpec(event: "UserPromptSubmit", matcher: nil, arguments: "acquire --hook"),
        HookSpec(event: "PreToolUse", matcher: "*", arguments: "acquire --hook"),
        HookSpec(event: "Stop", matcher: nil, arguments: "release --hook"),
        HookSpec(event: "StopFailure", matcher: nil, arguments: "release --hook"),
        HookSpec(event: "SessionEnd", matcher: nil, arguments: "release --hook"),
        HookSpec(event: "Notification", matcher: "idle_prompt|permission_prompt", arguments: "release --hook"),
    ]

    public static func command(executable: String, _ spec: HookSpec) -> String {
        shellQuote(executable) + " " + spec.arguments
    }

    /// A hook is Vigil's if its command runs a binary named `vigil` with `--hook`.
    public static func isOurs(command: String) -> Bool {
        let words = shellWords(command)
        guard let first = words.first else { return false }
        return (first as NSString).lastPathComponent == "vigil" && words.contains("--hook")
    }

    static func isOurHook(_ hook: JSONValue) -> Bool {
        hook["command"]?.stringValue.map(isOurs(command:)) ?? false
    }

    public enum EditError: Error, CustomStringConvertible, Equatable {
        case notAnObject(String)
        public var description: String {
            switch self {
            case .notAnObject(let what): return "\(what) in settings.json is not a JSON object; not touching it"
            }
        }
    }

    public static func install(into settings: JSONValue, executable: String) throws -> JSONValue {
        guard settings.isObject else { throw EditError.notAnObject("the top level") }
        var root = settings
        var hooks = root["hooks"] ?? .object([])
        guard hooks.isObject else { throw EditError.notAnObject("\"hooks\"") }
        hooks = strip(hooks).hooks
        for spec in specs {
            var groups = hooks[spec.event]?.arrayValue ?? []
            groups.append(group(for: spec, executable: executable))
            hooks.set(spec.event, .array(groups))
        }
        root.set("hooks", hooks)
        return root
    }

    public static func uninstall(from settings: JSONValue) throws -> JSONValue {
        guard settings.isObject else { throw EditError.notAnObject("the top level") }
        guard let hooks = settings["hooks"] else { return settings }
        guard hooks.isObject else { throw EditError.notAnObject("\"hooks\"") }
        var (stripped, emptied) = strip(hooks)
        guard case .object(let events) = stripped else { return settings }
        stripped = .object(events.filter { !emptied.contains($0.key) })
        var root = settings
        if case .object(let left) = stripped, left.isEmpty, !emptied.isEmpty {
            root.remove("hooks")
        } else {
            root.set("hooks", stripped)
        }
        return root
    }

    /// Events that currently run a Vigil hook.
    public static func installedEvents(in settings: JSONValue) -> [String] {
        guard case .object(let events)? = settings["hooks"] else { return [] }
        return events.compactMap { member in
            let groups = member.value.arrayValue ?? []
            let ours = groups.contains { ($0["hooks"]?.arrayValue ?? []).contains(where: isOurHook) }
            return ours ? member.key : nil
        }
    }

    private static func group(for spec: HookSpec, executable: String) -> JSONValue {
        var members: [JSONMember] = []
        if let matcher = spec.matcher { members.append(JSONMember(key: "matcher", value: .string(matcher))) }
        let hook: JSONValue = .object([
            JSONMember(key: "type", value: .string("command")),
            JSONMember(key: "command", value: .string(command(executable: executable, spec))),
            JSONMember(key: "timeout", value: .number(String(timeoutSeconds))),
        ])
        members.append(JSONMember(key: "hooks", value: .array([hook])))
        return .object(members)
    }

    /// Removes Vigil's hooks, dropping groups that held only them. Returns the events whose arrays
    /// this emptied, so uninstall can drop them without touching arrays the user left empty.
    private static func strip(_ hooks: JSONValue) -> (hooks: JSONValue, emptied: Set<String>) {
        guard case .object(let events) = hooks else { return (hooks, []) }
        var emptied: Set<String> = []
        let out = events.map { event -> JSONMember in
            guard case .array(let groups) = event.value else { return event }
            var kept: [JSONValue] = []
            for group in groups {
                guard let list = group["hooks"]?.arrayValue else { kept.append(group); continue }
                let others = list.filter { !isOurHook($0) }
                if others.count == list.count {
                    kept.append(group)
                } else if !others.isEmpty {
                    var g = group
                    g.set("hooks", .array(others))
                    kept.append(g)
                }
            }
            if kept.isEmpty, !groups.isEmpty { emptied.insert(event.key) }
            return JSONMember(key: event.key, value: .array(kept))
        }
        return (.object(out), emptied)
    }

    // MARK: Shell words

    public static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Splits a command line the way sh would for plain words, quotes and backslashes.
    static func shellWords(_ s: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; inWord = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else if ch == "\\" && q == "\"" { escaped = true } else { current.append(ch) }
                continue
            }
            switch ch {
            case "\\": escaped = true; inWord = true
            case "'", "\"": quote = ch; inWord = true
            case " ", "\t", "\n":
                if inWord { words.append(current); current = ""; inWord = false }
            default: current.append(ch); inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}
