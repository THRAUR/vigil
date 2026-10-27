import Foundation
import VigilCore

/// The two per-user launchd jobs: the watchdog (always) and the app itself (launch at login,
/// restarted by launchd if it crashes, not if you quit it).
enum LaunchAgents {
    static var domain: String { "gui/\(getuid())" }

    static func appAgent(executable: String) -> [String: Any] {
        [
            "Label": Labels.appAgent,
            "ProgramArguments": [executable, "app"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "StandardErrorPath": Paths.logs.appendingPathComponent("app.stderr.log").path,
        ]
    }

    static func watchdogAgent(executable: String) -> [String: Any] {
        [
            "Label": Labels.watchdogAgent,
            "ProgramArguments": [executable, "watchdog"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Standard",
            "ThrottleInterval": 10,
            "StandardErrorPath": Paths.logs.appendingPathComponent("watchdog.stderr.log").path,
        ]
    }

    static func writePlist(_ plist: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    static var launchAtLogin: Bool { FileManager.default.fileExists(atPath: Paths.appAgentPlist.path) }

    /// Takes effect at the next login. Bootstrapping now would start a second copy of the app.
    static func setLaunchAtLogin(_ on: Bool) throws {
        if on {
            try writePlist(appAgent(executable: SystemInfo.executablePath), to: Paths.appAgentPlist)
        } else if launchAtLogin {
            try FileManager.default.removeItem(at: Paths.appAgentPlist)
        }
    }

    struct JobInfo {
        var loaded: Bool
        var running: Bool
        var pid: Int32?
        var program: String?
    }

    static func info(_ label: String) -> JobInfo {
        let r = Shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"], timeout: 5)
        guard r.ok else { return JobInfo(loaded: false, running: false, pid: nil, program: nil) }
        // Only the job's own top-level keys (one tab deep); nested sections repeat "state = ".
        var info = JobInfo(loaded: true, running: false, pid: nil, program: nil)
        var seen: Set<String> = []
        for raw in r.output.split(separator: "\n") where raw.hasPrefix("\t") && !raw.hasPrefix("\t\t") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.range(of: " = ") else { continue }
            let key = String(line[..<eq.lowerBound]), value = String(line[eq.upperBound...])
            guard seen.insert(key).inserted else { continue }
            switch key {
            case "state": info.running = value == "running"
            case "pid": info.pid = Int32(value)
            case "program": info.program = value
            default: break
            }
        }
        return info
    }

    @discardableResult
    static func bootstrap(_ plist: URL) -> Shell.Result {
        Shell.run("/bin/launchctl", ["bootstrap", domain, plist.path], timeout: 10)
    }

    @discardableResult
    static func bootout(_ label: String) -> Shell.Result {
        Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 10)
    }

    @discardableResult
    static func kickstart(_ label: String) -> Shell.Result {
        Shell.run("/bin/launchctl", ["kickstart", "\(domain)/\(label)"], timeout: 10)
    }
}
