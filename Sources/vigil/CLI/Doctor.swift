import Darwin
import Foundation
import VigilCore

/// `vigil doctor`: checks every piece without changing anything (and without running sudo).
enum Doctor {
    static func run() -> Int32 {
        var problems = 0
        func line(_ ok: Bool?, _ text: String, fix: String? = nil) {
            print("\(ok.map { $0 ? "✓" : "✗" } ?? "•") \(text)")
            if ok == false {
                problems += 1
                if let fix { print("    → \(fix)") }
            }
        }
        let fm = FileManager.default
        let exe = SystemInfo.executablePath

        line(SystemInfo.appBundlePath != nil, "binary: \(exe)", fix: "run the copy inside ~/Applications/Vigil.app")
        let links = ["/opt/homebrew/bin/vigil", "/usr/local/bin/vigil"]
        let linked = links.first { link in
            var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
            return realpath(link, &resolved) != nil && String(cString: resolved) == exe
        }
        line(linked != nil ? true : nil, linked.map { "CLI on PATH: \($0)" } ?? "CLI not linked into /opt/homebrew/bin or /usr/local/bin (optional)")

        line(fm.fileExists(atPath: Labels.sudoersFile), "sudoers rule: \(Labels.sudoersFile)",
             fix: "run ./install.sh (asks for your password once)")
        line(fm.fileExists(atPath: Labels.bootResetPlist), "boot-time reset: \(Labels.bootResetPlist)", fix: "run ./install.sh")

        let dog = LaunchAgents.info(Labels.watchdogAgent)
        let dogText = dog.running ? "running (pid \(dog.pid.map(String.init) ?? "?"))" : dog.loaded ? "loaded but not running" : "not loaded"
        line(dog.running, "watchdog agent \(Labels.watchdogAgent): \(dogText)", fix: "re-run ./install.sh")
        if let program = dog.program, program != exe {
            line(false, "the watchdog runs \(program), not this binary", fix: "re-run ./install.sh")
        }

        if let s = (try? SocketClient.send(Request(.status), timeout: 3))?.status {
            line(true, "app: running (pid \(s.pid)): \(StatusText.headline(s))")
            if let error = s.flag.error { line(false, "last flag write failed: \(error)", fix: "run ./install.sh") }
            line(nil, "holds: \(s.holds.isEmpty ? "none" : s.holds.map { HoldText.title($0) }.joined(separator: ", "))")
        } else {
            line(false, "app: not running", fix: "open ~/Applications/Vigil.app")
        }
        let app = LaunchAgents.info(Labels.appAgent)
        line(nil, "launch at login: \(LaunchAgents.launchAtLogin ? "on" : "off")\(app.loaded ? ", app agent loaded" : "")")

        if let beat = Heartbeats.read() {
            let age = WatchdogLogic.ageSeconds(beat, nowUptimeNanos: SystemInfo.uptimeNanos())
            if beat.running {
                line(age <= WatchdogLogic.staleAfter, "heartbeat: \(Int(age))s old (stale after \(Int(WatchdogLogic.staleAfter))s)")
            } else {
                line(nil, "heartbeat: the app quit cleanly")
            }
        } else {
            line(nil, "heartbeat: none yet")
        }

        let kernel = FlagIO.readKernel(), pmset = FlagIO.readPmset()
        line(kernel == pmset, "SleepDisabled: kernel=\(bit(kernel)) pmset -g=\(bit(pmset))")

        var events: [String] = []
        if let text = try? String(contentsOf: Paths.claudeSettings, encoding: .utf8), let json = try? JSONParser.parse(text) {
            events = ClaudeHooks.installedEvents(in: json)
        }
        let all = events.count == ClaudeHooks.specs.count
        line(all ? true : events.isEmpty ? nil : false,
             "Claude Code hooks: \(all ? "installed" : events.isEmpty ? "not installed" : "partial (\(events.joined(separator: ", ")))")",
             fix: "vigil install-hooks")

        print(problems == 0 ? "\nAll good." : "\n\(problems) problem\(problems == 1 ? "" : "s").")
        return problems == 0 ? 0 : 1
    }
}

/// `vigil setup-agents`, run by install.sh from the installed binary.
enum Setup {
    static func agents(_ a: Args) throws -> Int32 {
        guard let bundle = SystemInfo.appBundlePath else {
            throw CLIError("run setup-agents from the installed Vigil.app binary")
        }
        let exe = SystemInfo.executablePath
        LaunchAgents.bootout(Labels.watchdogAgent)
        try LaunchAgents.writePlist(LaunchAgents.watchdogAgent(executable: exe), to: Paths.watchdogAgentPlist)
        let dog = LaunchAgents.bootstrap(Paths.watchdogAgentPlist)
        print(dog.ok ? "watchdog agent loaded" : "watchdog agent failed to load: \(dog.output.trimmingCharacters(in: .whitespacesAndNewlines))")

        LaunchAgents.bootout(Labels.appAgent)
        if a.flags.contains("--no-login") {
            try? FileManager.default.removeItem(at: Paths.appAgentPlist)
            _ = Shell.run("/usr/bin/open", ["-g", bundle])
            print("app started (launch at login off)")
        } else {
            try LaunchAgents.writePlist(LaunchAgents.appAgent(executable: exe), to: Paths.appAgentPlist)
            let app = LaunchAgents.bootstrap(Paths.appAgentPlist)
            print(app.ok ? "app agent loaded: starts at login, restarted if it crashes"
                  : "app agent failed to load: \(app.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        for _ in 0..<50 {
            if (try? SocketClient.send(Request(.ping), timeout: 1)) != nil {
                print("app is running")
                return dog.ok ? 0 : 1
            }
            usleep(150_000)
        }
        eprint("the app didn't come up; see ~/Library/Logs/Vigil/")
        return 1
    }
}
