import Darwin
import Foundation

enum SystemInfo {
    /// Changes on every boot; used to drop state left over from before a restart.
    static let bootSession: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }()

    /// Monotonic, shared by all processes, and paused while the Mac sleeps.
    static func uptimeNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    static func startTime(_ pid: pid_t) -> Double? {
        guard let info = kinfo(pid) else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }

    static func parent(_ pid: pid_t) -> pid_t? {
        kinfo(pid).map { $0.kp_eproc.e_ppid }
    }

    static func name(_ pid: pid_t) -> String? {
        guard let info = kinfo(pid) else { return nil }
        return withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Alive, and (if a start time is given) still the same process rather than a reused pid.
    static func isAlive(_ pid: pid_t, startTime: Double? = nil) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0, errno == ESRCH { return false }
        guard let expected = startTime, expected > 0 else { return true }
        guard let actual = self.startTime(pid) else { return false }
        return abs(actual - expected) < 0.01
    }

    /// The nearest ancestor whose name is in `names` (e.g. the `claude` process running a hook).
    static func ancestor(named names: Set<String>, from pid: pid_t = getppid(), maxDepth: Int = 8) -> pid_t? {
        var current = pid
        for _ in 0..<maxDepth {
            guard current > 1 else { return nil }
            if let n = name(current), names.contains(n) { return current }
            guard let p = parent(current), p != current else { return nil }
            current = p
        }
        return nil
    }

    /// This binary's real path (resolving the /opt/homebrew/bin/vigil symlink).
    static let executablePath: String = {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return CommandLine.arguments[0] }
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(buf, &resolved) != nil else { return String(cString: buf) }
        return String(cString: resolved)
    }()

    /// The .app bundle containing this binary, if it runs from one.
    static var appBundlePath: String? {
        let marker = ".app/Contents/MacOS/"
        guard let range = executablePath.range(of: marker, options: .backwards) else { return nil }
        return String(executablePath[..<range.lowerBound]) + ".app"
    }
}
