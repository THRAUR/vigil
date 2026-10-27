import Darwin
import Foundation
import VigilCore

extension CLI {
    /// `vigil install-hooks` / `uninstall-hooks`: shows the settings.json diff, then asks.
    static func hooks(_ a: Args, install: Bool) throws -> Int32 {
        let url = Paths.claudeSettings
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        let original = exists ? try String(contentsOf: url, encoding: .utf8) : ""
        let root: JSONValue
        do {
            root = original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .object([]) : try JSONParser.parse(original)
        } catch {
            throw CLIError("can't parse \(url.path): \(error)")
        }
        let executable = SystemInfo.appBundlePath.map { $0 + "/Contents/MacOS/vigil" } ?? SystemInfo.executablePath
        let updated = install ? try ClaudeHooks.install(into: root, executable: executable) : try ClaudeHooks.uninstall(from: root)
        var text = JSONPrinter.render(updated)
        if original.hasSuffix("\n") || !exists { text += "\n" }
        guard text != original else {
            print(install ? "The Vigil hooks are already in \(url.path)." : "No Vigil hooks in \(url.path).")
            return 0
        }

        print(unifiedDiff(old: original, new: text, name: "~/.claude/settings.json"))
        if a.flags.contains("--dry-run") { return 0 }
        if !a.flags.contains("--yes") {
            guard isatty(STDIN_FILENO) != 0 else {
                eprint("Not written. Re-run with --yes to apply this change.")
                return 2
            }
            print("Write this to \(url.path)? [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
                print("Left unchanged.")
                return 1
            }
        }

        var backup: String?
        if exists {
            let stamp = Log.timestamp().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ":", with: "")
            var path = url.path + ".vigil-backup-" + stamp
            var n = 2
            while fm.fileExists(atPath: path) {
                path = url.path + ".vigil-backup-" + stamp + "-\(n)"
                n += 1
            }
            try fm.copyItem(atPath: url.path, toPath: path)
            backup = path
        }
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o600
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        print("Wrote \(url.path)\(backup.map { " (backup: \(($0 as NSString).lastPathComponent))" } ?? "").")
        if install { print("Claude Code reloads settings on its own; new and running sessions use the hooks.") }
        return 0
    }

    static func unifiedDiff(old: String, new: String, name: String) -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vigil-diff-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("old"), b = dir.appendingPathComponent("new")
        try? Data(old.utf8).write(to: a)
        try? Data(new.utf8).write(to: b)
        let r = Shell.run("/usr/bin/diff", ["-u", "-L", "a/" + name, "-L", "b/" + name, a.path, b.path])
        return r.output.trimmingCharacters(in: .newlines)
    }
}
