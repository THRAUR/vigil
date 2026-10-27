import Darwin
import Foundation

/// Runs programs directly with posix_spawn (no shell). Children inherit only stdio, so they never
/// hold the app's lock file or socket, and get default signal handling back.
enum Shell {
    struct Result {
        var status: Int32
        var output: String
        var timedOut = false
        var ok: Bool { status == 0 && !timedOut }
    }

    private static let resetSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE]

    /// Captures stdout and stderr together. Kills the child after `timeout`.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> Result {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return Result(status: -1, output: "pipe: \(String(cString: strerror(errno)))") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)

        var pid: pid_t = 0
        let rc = spawn(&pid, path, [path] + args, &actions, searchPath: false)
        close(fds[1])
        guard rc == 0 else {
            close(fds[0])
            return Result(status: -1, output: "can't run \(path): \(String(cString: strerror(rc)))")
        }

        var output = Data()
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        var pfd = pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                timedOut = true
                kill(pid, SIGKILL)
                break
            }
            let ready = poll(&pfd, 1, Int32(min(remaining, 1) * 1000))
            if ready < 0 { if errno == EINTR { continue } else { break } }
            if ready == 0 { continue }
            let n = read(fds[0], &buffer, buffer.count)
            if n > 0 { output.append(contentsOf: buffer[0..<n]); continue }
            if n < 0, errno == EINTR { continue }
            break
        }
        close(fds[0])
        return Result(status: wait(pid), output: String(decoding: output, as: UTF8.self), timedOut: timedOut)
    }

    /// Fire and forget, off the calling thread.
    static func runDetached(_ path: String, _ args: [String]) {
        DispatchQueue.global(qos: .utility).async {
            let r = run(path, args)
            if !r.ok { Log.warn("\(path) \(args.joined(separator: " ")) failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
    }

    /// Starts a command that shares the terminal (for `vigil run`). Looks it up in PATH.
    static func spawnInteractive(_ argv: [String]) -> (pid: pid_t, error: Int32) {
        var pid: pid_t = 0
        let rc = spawn(&pid, argv[0], argv, nil, searchPath: true)
        return (pid, rc)
    }

    /// waitpid, returning the exit code (128 + signal if it was killed).
    static func wait(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { return -1 }
        }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func spawn(_ pid: inout pid_t, _ path: String, _ argv: [String],
                              _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>?, searchPath: Bool) -> Int32 {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var flags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        if actions != nil { flags |= POSIX_SPAWN_CLOEXEC_DEFAULT }
        posix_spawnattr_setflags(&attr, Int16(flags))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for s in resetSignals { sigaddset(&defaults, s) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for p in cArgs { free(p) } }
        return searchPath
            ? posix_spawnp(&pid, path, actions, &attr, cArgs, environ)
            : posix_spawn(&pid, path, actions, &attr, cArgs, environ)
    }
}
