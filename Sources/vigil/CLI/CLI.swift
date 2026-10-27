import Darwin
import Foundation
import VigilCore

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

/// Parsed command line: positionals, `--opt value` / `--opt=value`, bare flags, and words after `--`.
struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var rest: [String] = []

    init(_ args: [String], options valued: Set<String> = [], flags allowed: Set<String> = []) throws {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" {
                rest = Array(args[(i + 1)...])
                break
            }
            if a.hasPrefix("-"), a.count > 1, Int(a) == nil {
                let parts = a.split(separator: "=", maxSplits: 1).map(String.init)
                let name = parts[0]
                if valued.contains(name) {
                    if parts.count == 2 {
                        options[name] = parts[1]
                    } else {
                        guard i + 1 < args.count else { throw CLIError("\(name) needs a value") }
                        options[name] = args[i + 1]
                        i += 1
                    }
                } else if allowed.contains(name) {
                    flags.insert(name)
                } else {
                    throw CLIError("unknown option \(name)")
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }
}

enum CLI {
    static let usage = """
    vigil keeps this Mac awake with the lid closed, for agents and long jobs.

      vigil status [--json]            what holds the Mac awake, and the flag as read back
      vigil on [--reason TEXT]         keep awake until `vigil off` (the menu's Keep Awake)
      vigil off                        let it sleep: release every hold
      vigil hold --for 2h [--reason TEXT] [--id ID]
      vigil hold --pid PID [--for MAX] [--reason TEXT]       until that process exits
      vigil run [--reason TEXT] [--for MAX] -- CMD [ARGS…]   hold while CMD runs
      vigil release ID… | --all | --session ID
      vigil acquire --session ID [--reason TEXT] [--pid PID] agent holds, refreshed per call
      vigil acquire --hook | release --hook                 Claude Code hooks (JSON on stdin)
      vigil install-hooks [--dry-run] [--yes]   add the Claude Code hooks, showing the diff first
      vigil uninstall-hooks [--dry-run] [--yes]
      vigil config [KEY [VALUE]]       battery-floor, thermal-cutoff, only-on-ac, …
      vigil doctor                     check the whole install
      vigil log [-n LINES] [-f]
      vigil quit                       quit the app (it clears the flag on the way out)

    Durations: 90s, 45m, 2h, 1h30m; a bare number means minutes.
    If anything ever goes wrong: sudo pmset -a disablesleep 0   (a reboot clears it too)
    """

    static func main(_ argv: [String]) -> Int32 {
        Log.role = "cli"
        Paths.ensureDirectories()
        let command = argv.first ?? "status"
        let rest = Array(argv.dropFirst())
        do {
            switch command {
            case "status", "st": return try status(Args(rest, flags: ["--json"]))
            case "on": return try on(Args(rest, options: ["--reason"]))
            case "off", "sleep": return try off(Args(rest))
            case "hold": return try hold(Args(rest, options: ["--for", "--pid", "--reason", "--id"]))
            case "run": return try run(Args(rest, options: ["--reason", "--for"]))
            case "release": return try release(Args(rest, options: ["--session"], flags: ["--all", "--hook"]))
            case "acquire": return try acquire(Args(rest, options: ["--session", "--reason", "--pid"], flags: ["--hook"]))
            case "install-hooks": return try hooks(Args(rest, flags: ["--dry-run", "--yes"]), install: true)
            case "uninstall-hooks": return try hooks(Args(rest, flags: ["--dry-run", "--yes"]), install: false)
            case "config": return try config(Args(rest))
            case "doctor": return Doctor.run()
            case "log": return try log(Args(rest, options: ["-n"], flags: ["-f"]))
            case "quit": return quit()
            case "setup-agents": return try Setup.agents(Args(rest, flags: ["--no-login"]))
            case "version", "--version", "-v": print("vigil \(Version.string)"); return 0
            case "help", "--help", "-h": print(usage); return 0
            default:
                eprint("vigil: unknown command '\(command)'\n\n\(usage)")
                return 64
            }
        } catch let error as CLIError {
            eprint("vigil: \(error)")
            return 64
        } catch {
            eprint("vigil: \(error)")
            return 1
        }
    }

    // MARK: Talking to the app

    /// Sends a request, starting the app first if asked to and it isn't running.
    static func send(_ request: Request, launch: Bool, timeout: Double = 5) throws -> Response {
        do {
            return try SocketClient.send(request, timeout: timeout)
        } catch SocketClient.Failure.notRunning where launch {
            try launchApp()
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                usleep(150_000)
                do {
                    return try SocketClient.send(request, timeout: timeout)
                } catch SocketClient.Failure.notRunning {
                    continue
                }
            }
            throw SocketClient.Failure.notRunning
        }
    }

    static func launchApp() throws {
        if Paths.testHome != nil {
            // Test mode: start this binary directly so the app inherits the test environment.
            var pid: pid_t = 0
            let argv: [UnsafeMutablePointer<CChar>?] = [strdup(SystemInfo.executablePath), strdup("app"), nil]
            defer { argv.forEach { free($0) } }
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            for fd: Int32 in [0, 1, 2] { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0) }
            var attr: posix_spawnattr_t?
            posix_spawnattr_init(&attr)
            defer { posix_spawnattr_destroy(&attr) }
            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
            let rc = posix_spawn(&pid, SystemInfo.executablePath, &actions, &attr, argv, environ)
            if rc != 0 { throw CLIError("couldn't start the app: \(String(cString: strerror(rc)))") }
            return
        }
        if LaunchAgents.info(Labels.appAgent).loaded {
            LaunchAgents.kickstart(Labels.appAgent)
            return
        }
        guard let bundle = SystemInfo.appBundlePath else {
            throw CLIError("the Vigil app isn't running, and this vigil binary isn't inside Vigil.app")
        }
        let r = Shell.run("/usr/bin/open", ["-g", bundle], timeout: 10)
        if !r.ok { throw CLIError("couldn't open \(bundle): \(r.output)") }
    }

    /// After a change, wait briefly for the app's write-and-read-back and report the real flag.
    static func reportFlag() {
        let deadline = Date().addingTimeInterval(5)
        while true {
            guard let s = try? SocketClient.send(Request(.status), timeout: 3).status else { return }
            let settled = !s.flag.busy && (s.flag.kernel == s.wantAwake || s.flag.error != nil)
            if settled || Date() > deadline {
                if let error = s.flag.error, s.flag.kernel != s.wantAwake {
                    eprint("! \(error)")
                } else if s.demanded, !s.wantAwake {
                    print("Paused by safety (\(s.inhibitors.map(\.label).joined(separator: ", "))): SleepDisabled=\(bit(s.flag.kernel))")
                } else {
                    print("SleepDisabled=\(bit(s.flag.kernel)) (pmset -g: \(bit(s.flag.pmset)))")
                }
                return
            }
            usleep(200_000)
        }
    }

    // MARK: Commands

    static func status(_ a: Args) throws -> Int32 {
        do {
            let r = try SocketClient.send(Request(.status), timeout: 3)
            guard let s = r.status else { throw CLIError(r.error ?? "no status") }
            if a.flags.contains("--json") {
                let enc = Wire.encoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try enc.encode(s), as: UTF8.self))
            } else {
                print(StatusText.render(s))
            }
            return 0
        } catch SocketClient.Failure.notRunning {
            let kernel = FlagIO.readKernel(), pmset = FlagIO.readPmset()
            print("Vigil: the app isn't running (open ~/Applications/Vigil.app)")
            print("  Flag     SleepDisabled kernel=\(bit(kernel)) pmset=\(bit(pmset))")
            if kernel == true {
                print("  ! SleepDisabled is on with no app holding it. The watchdog clears it within a minute;")
                print("    to do it now: sudo pmset -a disablesleep 0")
            }
            return 3
        }
    }

    static func on(_ a: Args) throws -> Int32 {
        var req = Request(.hold)
        req.manual = true
        req.id = HoldID.manual
        req.reason = a.options["--reason"] ?? "Keep Awake"
        req.source = "cli"
        let r = try send(req, launch: true)
        guard r.ok else { throw CLIError(r.error ?? "failed") }
        print("Keeping the Mac awake until `vigil off`.")
        reportFlag()
        return 0
    }

    static func off(_ a: Args) throws -> Int32 {
        var req = Request(.release)
        req.all = true
        req.cause = .user
        do {
            let r = try SocketClient.send(req)
            guard r.ok else { throw CLIError(r.error ?? "failed") }
            let n = r.released?.count ?? 0
            print(n == 0 ? "Nothing was holding the Mac awake." : "Released \(n) hold\(n == 1 ? "" : "s").")
            reportFlag()
        } catch SocketClient.Failure.notRunning {
            print("Vigil isn't running; SleepDisabled=\(bit(FlagIO.readKernel())).")
        }
        return 0
    }

    static func hold(_ a: Args) throws -> Int32 {
        var req = Request(.hold)
        req.reason = a.options["--reason"]
        req.id = a.options["--id"]
        req.source = "cli"
        if let d = a.options["--for"] {
            guard let seconds = DurationText.parse(d) else { throw CLIError("can't read the duration '\(d)' (try 30m, 2h, 1h30m)") }
            req.seconds = seconds
        }
        if let p = a.options["--pid"] {
            guard let pid = Int32(p), pid > 0 else { throw CLIError("bad pid '\(p)'") }
            req.pid = pid
        }
        guard req.seconds != nil || req.pid != nil else {
            throw CLIError("hold needs --for DURATION or --pid PID (or `vigil on` to hold until `vigil off`)")
        }
        let r = try send(req, launch: true)
        guard r.ok, let h = r.hold else { throw CLIError(r.error ?? "failed") }
        print("Holding awake: \(HoldText.title(h)), \(HoldText.detail(h, now: Date())). Release early: vigil release \(h.id)")
        reportFlag()
        return 0
    }

    static func run(_ a: Args) throws -> Int32 {
        guard let program = a.rest.first else { throw CLIError("usage: vigil run [--reason TEXT] [--for MAX] -- COMMAND [ARGS…]") }
        var cap: Double?
        if let d = a.options["--for"] {
            guard let s = DurationText.parse(d) else { throw CLIError("can't read the duration '\(d)'") }
            cap = s
        }
        let (pid, err) = Shell.spawnInteractive(a.rest)
        guard err == 0 else {
            eprint("vigil: can't run \(program): \(String(cString: strerror(err)))")
            return 127
        }
        // Ctrl-C reaches the child (same process group); we stay to release the hold.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        var req = Request(.hold)
        req.pid = pid
        req.id = "run-\(pid)"
        req.seconds = cap
        req.reason = a.options["--reason"] ?? (program as NSString).lastPathComponent
        req.source = "vigil run"
        var holdID: String?
        do {
            let r = try send(req, launch: true)
            if r.ok, let h = r.hold {
                holdID = h.id
                eprint("vigil: holding the Mac awake while \(HoldText.title(h)) runs [\(h.id)]")
            } else {
                eprint("vigil: couldn't hold: \(r.error ?? "unknown error")")
            }
        } catch {
            eprint("vigil: couldn't reach the app (\(error)); running without a hold")
        }
        let status = Shell.wait(pid)
        if let holdID {
            var rel = Request(.release)
            rel.ids = [holdID]
            rel.cause = .agent
            _ = try? SocketClient.send(rel)
        }
        return status
    }

    static func release(_ a: Args) throws -> Int32 {
        if a.flags.contains("--hook") { return Hook.run(fallback: .release(soft: false)) }
        var req = Request(.release)
        if a.flags.contains("--all") {
            req.all = true
            req.cause = .user
        } else if let sid = a.options["--session"] {
            req.session = sid
            req.cause = .agent
        } else if !a.positional.isEmpty {
            req.ids = a.positional
            req.cause = .user
        } else {
            throw CLIError("usage: vigil release ID… | --all | --session ID")
        }
        do {
            let r = try SocketClient.send(req)
            guard r.ok else { throw CLIError(r.error ?? "failed") }
            let gone = r.released ?? []
            if gone.isEmpty { print("Nothing to release.") }
            for h in gone { print("Released \(HoldText.title(h)) [\(h.id)]") }
            if !gone.isEmpty { reportFlag() }
        } catch SocketClient.Failure.notRunning {
            print("Vigil isn't running; nothing to release.")
        }
        return 0
    }

    static func acquire(_ a: Args) throws -> Int32 {
        if a.flags.contains("--hook") { return Hook.run(fallback: .acquire(.prompt)) }
        guard let sid = a.options["--session"], !sid.isEmpty else {
            throw CLIError("usage: vigil acquire --session ID [--reason TEXT] [--pid PID]   (or --hook)")
        }
        var req = Request(.acquire)
        req.session = sid
        req.trigger = .prompt
        req.reason = a.options["--reason"] ?? "Session \(sid.prefix(12))"
        req.source = "cli"
        if let p = a.options["--pid"] {
            guard let pid = Int32(p), pid > 0 else { throw CLIError("bad pid '\(p)'") }
            req.pid = pid
        }
        let r = try send(req, launch: true)
        guard r.ok else { throw CLIError(r.error ?? "failed") }
        print("\(r.outcome?.rawValue ?? "ok"): \(r.hold.map { HoldText.title($0) + " [" + $0.id + "]" } ?? sid)")
        return 0
    }

    static func config(_ a: Args) throws -> Int32 {
        var req = Request(.config)
        if let key = a.positional.first { req.key = key }
        if a.positional.count > 1 { req.value = a.positional.dropFirst().joined(separator: " ") }
        let r = try send(req, launch: true)
        guard r.ok, let values = r.settings else { throw CLIError(r.error ?? "failed") }
        if let key = req.key {
            print("\(key) = \(values[key] ?? "?")")
        } else {
            for (key, help) in Settings.keys {
                print("\(key.padding(toLength: 16, withPad: " ", startingAt: 0)) \((values[key] ?? "?").padding(toLength: 8, withPad: " ", startingAt: 0))  \(help)")
            }
        }
        return 0
    }

    static func log(_ a: Args) throws -> Int32 {
        let lines = a.options["-n"] ?? "40"
        guard Int(lines) != nil else { throw CLIError("-n needs a number") }
        var args = ["/usr/bin/tail", "-n", lines]
        if a.flags.contains("-f") { args.append("-F") }
        args.append(Paths.log.path)
        let cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        execv(args[0], cArgs)
        throw CLIError("couldn't run tail: \(String(cString: strerror(errno)))")
    }

    static func quit() -> Int32 {
        do {
            _ = try SocketClient.send(Request(.quit))
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, (try? SocketClient.send(Request(.ping), timeout: 1)) != nil { usleep(150_000) }
            print("Vigil quit. SleepDisabled=\(bit(FlagIO.readKernel()))")
        } catch {
            print("Vigil isn't running.")
        }
        return 0
    }
}

func eprint(_ s: String) {
    fflush(stdout)
    FileHandle.standardError.write(Data((s + "\n").utf8))
}
