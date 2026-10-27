import Foundation
import Testing
@testable import VigilCore

@Suite struct Durations {
    @Test(arguments: [
        ("90s", 90.0), ("45m", 2700), ("2h", 7200), ("1h30m", 5400), ("1.5h", 5400),
        ("2 hours", 7200), ("30min", 1800), ("1d", 86400), ("45", 2700), ("1h 15m 30s", 4530),
    ])
    func parses(_ text: String, _ seconds: Double) {
        #expect(DurationText.parse(text) == seconds)
    }

    @Test(arguments: ["", "abc", "2x", "h", "-5", "0", "0m", "1h-2m"])
    func rejects(_ text: String) {
        #expect(DurationText.parse(text) == nil)
    }

    @Test func formats() {
        #expect(DurationText.format(42) == "42s")
        #expect(DurationText.format(12 * 60) == "12m")
        #expect(DurationText.format(3600) == "1h")
        #expect(DurationText.format(3600 + 5 * 60) == "1h 5m")
        #expect(DurationText.format(2 * 86400 + 3 * 3600) == "2d 3h")
        #expect(DurationText.format(-5) == "0s")
    }
}

@Suite struct Pmset {
    let off = """
    System-wide power settings:
    Currently in use:
     standby              1
     sleep                1 (sleep prevented by coreaudiod, powerd)
     displaysleep         0
    """
    let on = """
    System-wide power settings:
     SleepDisabled\t\t1
    Currently in use:
     standby              1
    """

    @Test func readsFlag() {
        #expect(PmsetOutput.sleepDisabled(in: off) == false)
        #expect(PmsetOutput.sleepDisabled(in: on) == true)
        #expect(PmsetOutput.sleepDisabled(in: on.replacingOccurrences(of: "\t\t1", with: " 0")) == false)
    }

    @Test func rejectsNonPmsetOutput() {
        #expect(PmsetOutput.sleepDisabled(in: "pmset: command not found") == nil)
    }

    @Test func explainsSudoFailures() {
        #expect(SudoError.describe(status: 1, output: "sudo: a password is required\n").contains("sudoers rule"))
        #expect(SudoError.describe(status: 3, output: "") == "sudo pmset exited with status 3")
    }
}

@Suite struct Hooks {
    @Test func parsesHookInput() {
        let json = #"{"session_id":"s-1","hook_event_name":"Stop","cwd":"/Volumes/X/Blender","background_tasks":[{"id":"b1"},{"id":"b2"}],"session_crons":[]}"#
        let input = HookInput.parse(Data(json.utf8))
        #expect(input?.sessionID == "s-1")
        #expect(input?.event == "Stop")
        #expect(input?.pendingBackgroundWork == 2)
        #expect(input?.holdReason == "Claude · Blender")
        #expect(HookInput.parse(Data("not json".utf8)) == nil)
    }

    @Test func scansHugeInputs() {
        let big = String(repeating: "x", count: 3 << 20)
        let json = #"{"session_id":"s-2","transcript_path":"/t","cwd":"/a/b \"q\"","hook_event_name":"PreToolUse","tool_input":{"content":"\#(big)"}}"#
        let input = HookInput.scan(Data(json.utf8))
        #expect(input?.sessionID == "s-2")
        #expect(input?.event == "PreToolUse")
        #expect(input?.cwd == "/a/b \"q\"")
        #expect(HookInput.scan(Data("{}".utf8)) == nil)
    }

    @Test func mapsEventsToActions() {
        func act(_ event: String, type: String? = nil, agent: String? = nil, pending: Int = 0) -> HookAction {
            HookPolicy.action(for: HookInput(sessionID: "s", event: event, notificationType: type, agentID: agent, pendingBackgroundWork: pending))
        }
        #expect(act("UserPromptSubmit") == .acquire(.prompt))
        #expect(act("PreToolUse") == .acquire(.activity))
        #expect(act("PreToolUse", agent: "sub-1") == .acquire(.refresh))
        #expect(act("Stop") == .release(soft: false))
        #expect(act("Stop", pending: 1) == .park(pending: 1))
        #expect(act("StopFailure") == .release(soft: false))
        #expect(act("SessionEnd") == .release(soft: false))
        #expect(act("Notification", type: "idle_prompt") == .release(soft: true))
        #expect(act("Notification", type: "permission_prompt") == .release(soft: true))
        #expect(act("Notification", type: "auth_success") == .ignore)
        #expect(act("SubagentStop") == .ignore)
    }

    @Test func countsWhateverShape() {
        #expect(HookInput.count(nil) == 0)
        #expect(HookInput.count([1, 2, 3]) == 3)
        #expect(HookInput.count(["a": 1]) == 1)
        #expect(HookInput.count(NSNumber(value: 4)) == 4)
        #expect(HookInput.count(true) == 1)
    }

    @Test func reasonFallsBack() {
        #expect(HookInput(cwd: nil).holdReason == "Claude Code")
        #expect(HookInput(cwd: "/").holdReason == "Claude Code")
    }
}

@Suite struct WatchdogVerdicts {
    let boot = "BOOT-1"
    func hb(running: Bool = true, uptime: UInt64 = 1_000_000_000_000, boot: String = "BOOT-1") -> Heartbeat {
        Heartbeat(pid: 77, pidStartTime: 5, uptimeNanos: uptime, bootSession: boot, wall: Date(), running: running, wantsAwake: true)
    }
    let alive: (Int32, Double) -> Bool = { _, _ in true }
    let dead: (Int32, Double) -> Bool = { _, _ in false }

    @Test func classifies() {
        let now: UInt64 = 1_000_000_000_000 + 30_000_000_000 // 30 s later
        #expect(WatchdogLogic.verdict(hb(), nowUptimeNanos: now, bootSession: boot, isAlive: alive) == .healthy)
        #expect(WatchdogLogic.verdict(nil, nowUptimeNanos: now, bootSession: boot, isAlive: alive) == .noHeartbeat)
        #expect(WatchdogLogic.verdict(hb(boot: "OLD"), nowUptimeNanos: now, bootSession: boot, isAlive: alive) == .otherBoot)
        #expect(WatchdogLogic.verdict(hb(running: false), nowUptimeNanos: now, bootSession: boot, isAlive: alive) == .stopped)
        #expect(WatchdogLogic.verdict(hb(), nowUptimeNanos: now, bootSession: boot, isAlive: dead) == .dead)
        let late: UInt64 = 1_000_000_000_000 + 91_000_000_000
        #expect(WatchdogLogic.verdict(hb(), nowUptimeNanos: late, bootSession: boot, isAlive: alive) == .hung(seconds: 91))
        #expect(WatchdogVerdict.hung(seconds: 91).label == "is unresponsive (91 s without a heartbeat)")
    }

    @Test func clearsOnlyWhenFlagIsOnAndAppCantVouch() {
        #expect(!WatchdogLogic.mustClear(.healthy, flagOn: true))
        #expect(!WatchdogLogic.mustClear(.dead, flagOn: false))
        #expect(WatchdogLogic.mustClear(.dead, flagOn: true))
        #expect(WatchdogLogic.mustClear(.hung(seconds: 95), flagOn: true))
        #expect(WatchdogLogic.mustClear(.noHeartbeat, flagOn: true))
        #expect(WatchdogLogic.mustClear(.stopped, flagOn: true))
    }

    @Test func wakesExactlyWhenTheBeatWouldGoStale() {
        let beat = hb()
        let at30 = beat.uptimeNanos + 30_000_000_000
        #expect(WatchdogLogic.nextCheckDelay(.healthy, beat, nowUptimeNanos: at30) == 60)  // capped
        let at80 = beat.uptimeNanos + 80_000_000_000
        #expect(WatchdogLogic.nextCheckDelay(.healthy, beat, nowUptimeNanos: at80) == 11)
        #expect(WatchdogLogic.nextCheckDelay(.dead, beat, nowUptimeNanos: at80) == 60)
    }
}

@Suite struct SettingsKeys {
    @Test func setAndRead() throws {
        var s = Settings()
        try s.set("battery-floor", to: "25%")
        try s.set("thermal-cutoff", to: "critical")
        try s.set("only-on-ac", to: "on")
        try s.set("session-idle", to: "90m")
        try s.set("battery-floor", to: "25")
        #expect(s.batteryFloor == 25 && s.thermalCutoff == .critical && s.onlyOnAC && s.sessionIdleTimeout == 5400)
        #expect(s.value(for: "battery-floor") == "25%")
        #expect(s.value(for: "session-idle") == "1h 30m")
        try s.set("battery-floor", to: "off")
        #expect(s.value(for: "battery-floor") == "off")
    }

    @Test func rejectsBadInput() {
        var s = Settings()
        #expect(throws: Settings.ConfigError.self) { try s.set("battery-floor", to: "95") }
        #expect(throws: Settings.ConfigError.self) { try s.set("thermal-cutoff", to: "fair") }
        #expect(throws: Settings.ConfigError.self) { try s.set("nope", to: "1") }
        #expect(throws: Settings.ConfigError.self) { try s.set("session-idle", to: "10s") }
    }

    @Test func decodesOldFilesWithDefaults() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"batteryFloor": 30}"#.utf8))
        #expect(s.batteryFloor == 30)
        #expect(s.thermalCutoff == .serious && s.pauseInLowPowerMode && s.displayOffOnLidClose)
    }

    @Test func everyKeyHasAValue() {
        let s = Settings()
        for (key, _) in Settings.keys { #expect(s.value(for: key) != nil, "\(key)") }
    }
}
