import Darwin
import Foundation
import os
import VigilCore

/// State changes go to ~/Library/Logs/Vigil/vigil.log (shared by app, watchdog and CLI) and to
/// the unified log. Writes are rare: only when something actually changes.
enum Log {
    static var role = "app"
    private static let lock = NSLock()
    private static let maxBytes: off_t = 1 << 20
    private static let logger = Logger(subsystem: Labels.bundleID, category: "vigil")

    static func info(_ message: String) { write(nil, message) }
    static func warn(_ message: String) { write("WARNING", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String?, _ message: String) {
        let role = self.role
        logger.log("[\(role, privacy: .public)] \(message, privacy: .public)")
        let line = "\(timestamp()) [\(role)] \(level.map { $0 + ": " } ?? "")\(message)\n"
        lock.lock()
        defer { lock.unlock() }
        let path = Paths.log.path
        var st = stat()
        if stat(path, &st) == 0, st.st_size > maxBytes {
            rename(path, path + ".1")
        }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        line.withCString { _ = Darwin.write(fd, $0, strlen($0)) }
        close(fd)
    }

    static func timestamp(_ date: Date = Date()) -> String {
        var t = time_t(date.timeIntervalSince1970)
        var parts = tm()
        localtime_r(&t, &parts)
        var buf = [CChar](repeating: 0, count: 32)
        strftime(&buf, buf.count, "%Y-%m-%d %H:%M:%S", &parts)
        return String(cString: buf)
    }
}
