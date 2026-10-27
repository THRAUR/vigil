import Foundation

public enum PmsetOutput {
    /// SleepDisabled from `pmset -g`. pmset lists it under "System-wide power settings:" only
    /// while it is set, so a missing line means 0. Returns nil if this doesn't look like pmset -g.
    public static func sleepDisabled(in output: String) -> Bool? {
        guard output.contains("System-wide power settings") || output.contains("Currently in use") else { return nil }
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count >= 2, fields[0] == "SleepDisabled" { return fields[1] == "1" }
        }
        return false
    }
}

/// Makes sudo's failures readable in the menu.
public enum SudoError {
    public static func describe(status: Int32, output: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("password is required") || text.contains("a terminal is required") {
            return "sudo wants a password: the Vigil sudoers rule isn't installed (run install.sh)"
        }
        if text.contains("not allowed") || text.contains("may not run") {
            return "sudoers doesn't allow this pmset call (re-run install.sh)"
        }
        return text.isEmpty ? "sudo pmset exited with status \(status)" : text
    }
}
