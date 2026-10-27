import Darwin

/// Last-ditch cleanup if the app crashes while SleepDisabled may be on: the signal handler spawns
/// `sudo -n pmset -a disablesleep 0` (everything preallocated), then lets the crash continue so a
/// crash report is still written. The watchdog covers SIGKILL and anything this misses.
enum CrashGuard {
    /// Non-zero while the flag may be on. Read from the signal handler.
    static var armed: Int32 = 0
    fileprivate static var path: UnsafeMutablePointer<CChar>?
    fileprivate static var argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    fileprivate static var envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?

    static func install() {
        let args = ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: args.count + 1)
        for (i, arg) in args.enumerated() { argv[i] = strdup(arg) }
        argv[args.count] = nil
        let envp = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 2)
        envp[0] = strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin")
        envp[1] = nil
        self.path = strdup(args[0])
        self.argv = argv
        self.envp = envp
        armed = 0

        // A stack of its own, so even a stack overflow can run the handler.
        let size = 64 * 1024
        var stack = stack_t(ss_sp: UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16), ss_size: size, ss_flags: 0)
        sigaltstack(&stack, nil)

        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGSYS] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = crashHandler
            action.sa_flags = SA_ONSTACK | SA_RESETHAND
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }
    }
}

private func crashHandler(_ sig: Int32) {
    if CrashGuard.armed != 0, let path = CrashGuard.path {
        alarm(3) // if the spawn wedges, SIGALRM ends the process anyway
        var pid: pid_t = 0
        if posix_spawn(&pid, path, nil, nil, CrashGuard.argv, CrashGuard.envp) == 0 {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }
    raise(sig) // the handler was reset to the default, so this crashes normally
}
