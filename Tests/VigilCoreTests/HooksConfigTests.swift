import Foundation
import Testing
@testable import VigilCore

private let exe = "/Users/me/Applications/Vigil.app/Contents/MacOS/vigil"

/// Shaped like a real ~/.claude/settings.json (written by Claude Code with 2-space indent).
private let sampleSettings = """
{
  "modelSettings": {
    "claude-opus-5-5": {
      "effortLevel": "xhigh"
    }
  },
  "skipWorkflowUsageWarning": true,
  "theme": "dark",
  "agentPushNotifEnabled": true,
  "model": "sonnet"
}
"""

private let withForeignHooks = """
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/bin/audit.sh"
          }
        ]
      }
    ],
    "Stop": []
  },
  "theme": "light"
}
"""

@Suite struct OrderedJSONRoundTrip {
    @Test func printsLikeJSONStringify() throws {
        #expect(JSONPrinter.render(try JSONParser.parse(sampleSettings)) == sampleSettings)
        #expect(JSONPrinter.render(try JSONParser.parse(withForeignHooks)) == withForeignHooks)
    }

    @Test func keepsNumbersAndEscapes() throws {
        let text = #"{"a":1.50,"b":-2e10,"c":"tab\there \"q\" \\ é 🎬 \u0001","d":[],"e":{},"f":null,"g":[true,false]}"#
        let v = try JSONParser.parse(text)
        #expect(v["a"] == .number("1.50"))
        #expect(v["b"] == .number("-2e10"))
        #expect(v["c"] == .string("tab\there \"q\" \\ é 🎬 \u{01}"))
        let printed = JSONPrinter.render(v)
        #expect(printed.contains(#""c": "tab\there \"q\" \\ é 🎬 \u0001""#))
        #expect(printed.contains(#""d": []"#) && printed.contains(#""e": {}"#))
        #expect(try JSONParser.parse(printed) == v)
    }

    @Test func decodesSurrogatePairs() throws {
        #expect(try JSONParser.parse(#""🎬""#) == .string("🎬"))
    }

    @Test(arguments: ["{", "[1,]", #"{"a" 1}"#, "tru", "01x", #""\x""#, "{} {}", "\"a\nb\""])
    func rejectsInvalid(_ text: String) {
        #expect(throws: JSONParseError.self) { try JSONParser.parse(text) }
    }

    @Test func setKeepsPositionAndAppendsNew() throws {
        var v = try JSONParser.parse(#"{"a":1,"b":2}"#)
        v.set("a", .number("9"))
        v.set("c", .number("3"))
        #expect(JSONPrinter.render(v) == "{\n  \"a\": 9,\n  \"b\": 2,\n  \"c\": 3\n}")
        v.remove("b")
        #expect(JSONPrinter.render(v) == "{\n  \"a\": 9,\n  \"c\": 3\n}")
    }
}

@Suite struct ClaudeHookEdits {
    @Test func installAddsEveryEventAndKeepsTheRest() throws {
        let original = try JSONParser.parse(sampleSettings)
        let installed = try ClaudeHooks.install(into: original, executable: exe)
        #expect(ClaudeHooks.installedEvents(in: installed) == ClaudeHooks.specs.map(\.event))
        #expect(installed["theme"] == .string("dark"))
        #expect(installed["model"] == .string("sonnet"))
        let text = JSONPrinter.render(installed)
        #expect(text.hasPrefix(String(sampleSettings.dropLast(2))))  // old keys untouched, hooks appended
        #expect(text.contains(#""command": "\#(exe) acquire --hook""#))
        #expect(text.contains(#""matcher": "idle_prompt|permission_prompt""#))
        #expect(text.contains(#""timeout": 10"#))
    }

    @Test func installIsIdempotent() throws {
        let once = try ClaudeHooks.install(into: try JSONParser.parse(sampleSettings), executable: exe)
        let twice = try ClaudeHooks.install(into: once, executable: exe)
        #expect(once == twice)
    }

    @Test func uninstallRestoresTheOriginalExactly() throws {
        let parsed = try JSONParser.parse(sampleSettings)
        let round = try ClaudeHooks.uninstall(from: ClaudeHooks.install(into: parsed, executable: exe))
        #expect(JSONPrinter.render(round) == sampleSettings)
    }

    @Test func uninstallDropsAnEmptyArrayItHadFilled() throws {
        // The user's own "Stop": [] can't be told apart from one Vigil emptied; dropping it is harmless.
        let parsed = try JSONParser.parse(withForeignHooks)
        let round = try ClaudeHooks.uninstall(from: ClaudeHooks.install(into: parsed, executable: exe))
        var expected = parsed
        var hooks = expected["hooks"]!
        hooks.remove("Stop")
        expected.set("hooks", hooks)
        #expect(JSONPrinter.render(round) == JSONPrinter.render(expected))
    }

    @Test func foreignHooksSurvive() throws {
        let installed = try ClaudeHooks.install(into: try JSONParser.parse(withForeignHooks), executable: exe)
        let pre = installed["hooks"]?["PreToolUse"]?.arrayValue ?? []
        #expect(pre.count == 2)
        #expect(pre.first?["matcher"] == .string("Bash"))
        let removed = try ClaudeHooks.uninstall(from: installed)
        #expect(ClaudeHooks.installedEvents(in: removed).isEmpty)
        #expect(removed["hooks"]?["PreToolUse"]?.arrayValue?.count == 1)
        #expect(removed["theme"] == .string("light"))
    }

    @Test func reinstallUpdatesTheBinaryPath() throws {
        let old = try ClaudeHooks.install(into: try JSONParser.parse(sampleSettings), executable: "/old/place/vigil")
        let new = try ClaudeHooks.install(into: old, executable: exe)
        let text = JSONPrinter.render(new)
        #expect(!text.contains("/old/place"))
        #expect(new["hooks"]?["Stop"]?.arrayValue?.count == 1)
    }

    @Test func recognisesOnlyOurCommands() {
        #expect(ClaudeHooks.isOurs(command: "\(exe) acquire --hook"))
        #expect(ClaudeHooks.isOurs(command: "'/path with space/vigil' release --hook"))
        #expect(!ClaudeHooks.isOurs(command: "\(exe) status"))
        #expect(!ClaudeHooks.isOurs(command: "~/bin/vigilant --hook"))
        #expect(!ClaudeHooks.isOurs(command: "echo vigil --hook"))
    }

    @Test func quotesPathsThatNeedIt() {
        #expect(ClaudeHooks.shellQuote(exe) == exe)
        #expect(ClaudeHooks.shellQuote("/a b/vigil") == "'/a b/vigil'")
        #expect(ClaudeHooks.shellQuote("/it's/vigil") == #"'/it'\''s/vigil'"#)
        #expect(ClaudeHooks.shellWords(#"'/it'\''s/vigil' x"#) == ["/it's/vigil", "x"])
    }

    @Test func refusesToEditNonObjects() throws {
        #expect(throws: ClaudeHooks.EditError.self) { try ClaudeHooks.install(into: .array([]), executable: exe) }
        let bad = try JSONParser.parse(#"{"hooks": []}"#)
        #expect(throws: ClaudeHooks.EditError.self) { try ClaudeHooks.install(into: bad, executable: exe) }
    }
}

@Suite struct StatusLines {
    func status(want: Bool, demanded: Bool, kernel: Bool?, error: String? = nil, inhibitors: [Inhibitor] = [], battery: Bool = false) -> StatusInfo {
        StatusInfo(version: "t", pid: 1, now: Date(), wantAwake: want, demanded: demanded, inhibitors: inhibitors,
                   flag: FlagState(kernel: kernel, pmset: kernel, target: want, busy: false, error: error, verifiedAt: nil),
                   holds: [], conditions: Conditions(power: PowerSnapshot(onAC: !battery, hasBattery: true, batteryPercent: 50, isCharging: false),
                                                     thermal: .nominal, lowPowerMode: false, lidClosed: false),
                   settings: Settings(), externalDisplay: false)
    }

    @Test func headlines() {
        #expect(StatusText.headline(status(want: false, demanded: false, kernel: false)) == "Sleeping normally")
        #expect(StatusText.headline(status(want: true, demanded: true, kernel: true)) == "Awake, lid can close")
        #expect(StatusText.headline(status(want: true, demanded: true, kernel: true, battery: true)) == "Awake on battery, lid can close")
        #expect(StatusText.headline(status(want: false, demanded: true, kernel: false, inhibitors: [.batteryFloor])).hasPrefix("Paused (battery at floor)"))
        #expect(StatusText.headline(status(want: true, demanded: true, kernel: false, error: "boom")) == "Can't keep awake: boom")
    }

    @Test func holdDetails() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let timed = Hold(id: "t", kind: .timed, reason: "render", source: "cli", createdAt: now, expiresAt: now.addingTimeInterval(3600 + 600))
        #expect(HoldText.detail(timed, now: now) == "1h 10m left")
        let session = Hold(id: "s", kind: .session, reason: "Claude · x", source: "claude", createdAt: now,
                           lastSeen: now.addingTimeInterval(-120), idleTimeout: 7200)
        #expect(HoldText.detail(session, now: now) == "active 2m ago · auto-release after 2h idle")
        var parked = session
        parked.parkedOnBackground = 1
        #expect(HoldText.detail(parked, now: now).hasPrefix("waiting on 1 background task ·"))
        let proc = Hold(id: "p", kind: .process, reason: "", source: "cli", createdAt: now, pid: 42)
        #expect(HoldText.title(proc) == "pid 42")
        #expect(HoldText.detail(proc, now: now) == "until pid 42 exits")
    }
}
