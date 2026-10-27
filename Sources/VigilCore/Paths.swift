import Foundation

public enum Labels {
    public static let bundleID = "local.vigil"
    public static let appAgent = "local.vigil"
    public static let watchdogAgent = "local.vigil.watchdog"
    public static let bootResetDaemon = "local.vigil.bootreset"
    public static let sudoersFile = "/etc/sudoers.d/vigil"
    public static let bootResetPlist = "/Library/LaunchDaemons/local.vigil.bootreset.plist"
}

public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    /// Test mode: keep all state, the socket and logs under $VIGIL_HOME instead of ~/Library.
    public static var testHome: URL? {
        ProcessInfo.processInfo.environment["VIGIL_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    public static var support: URL {
        testHome?.appendingPathComponent("support", isDirectory: true)
            ?? home.appendingPathComponent("Library/Application Support/Vigil", isDirectory: true)
    }
    public static var logs: URL {
        testHome?.appendingPathComponent("logs", isDirectory: true) ?? home.appendingPathComponent("Library/Logs/Vigil", isDirectory: true)
    }
    public static var socket: URL { support.appendingPathComponent("vigil.sock") }
    public static var state: URL { support.appendingPathComponent("state.json") }
    public static var heartbeat: URL { support.appendingPathComponent("heartbeat.json") }
    public static var watchdogMark: URL { support.appendingPathComponent("watchdog-cleared.json") }
    public static var lock: URL { support.appendingPathComponent("app.lock") }
    public static var log: URL { logs.appendingPathComponent("vigil.log") }
    public static var launchAgents: URL { home.appendingPathComponent("Library/LaunchAgents", isDirectory: true) }
    public static var appAgentPlist: URL { launchAgents.appendingPathComponent(Labels.appAgent + ".plist") }
    public static var watchdogAgentPlist: URL { launchAgents.appendingPathComponent(Labels.watchdogAgent + ".plist") }
    public static var claudeSettings: URL {
        ProcessInfo.processInfo.environment["VIGIL_CLAUDE_SETTINGS"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude/settings.json")
    }

    public static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [support, logs] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

public enum Version {
    public static let string = "0.1.0"
}
