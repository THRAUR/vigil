import Foundation
import VigilCore

/// `vigil watchdog`, run by its own LaunchAgent (KeepAlive). It watches the app's process for exit
/// (instant) and its heartbeat for staleness (> 90 s, i.e. hung), and clears SleepDisabled when the
/// app can't vouch for it. Between checks it sleeps; a check is a file read and an IOKit read.
enum WatchdogMain {
    static func run() -> Never {
        Log.role = "watchdog"
        Paths.ensureDirectories()
        let dog = Watchdog()
        dog.start()
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler {
            Log.info("watchdog stopping")
            exit(0)
        }
        term.resume()
        withExtendedLifetime((dog, term)) { dispatchMain() }
    }
}

final class Watchdog {
    private let timer = DispatchSource.makeTimerSource(queue: .main)
    private var exitSource: DispatchSourceProcess?
    private var watchedPID: Int32 = 0
    private var lastVerdict: WatchdogVerdict?

    func start() {
        Log.info("watchdog \(Version.string) started (pid \(getpid()))")
        timer.setEventHandler { [weak self] in self?.check() }
        timer.schedule(deadline: .now())
        timer.resume()
    }

    private func check() {
        let beat = Heartbeats.read()
        let now = SystemInfo.uptimeNanos()
        let verdict = WatchdogLogic.verdict(beat, nowUptimeNanos: now, bootSession: SystemInfo.bootSession) { pid, start in
            SystemInfo.isAlive(pid, startTime: start)
        }
        if verdict != lastVerdict, verdict == .healthy || lastVerdict == .healthy {
            Log.info("app \(verdict.label)\(beat.map { " (pid \($0.pid))" } ?? "")")
        }
        lastVerdict = verdict

        if verdict == .healthy, let beat {
            watch(beat.pid)
        } else {
            unwatch()
            let flagOn = FlagIO.readKernel() ?? FlagIO.readPmset() ?? false
            if WatchdogLogic.mustClear(verdict, flagOn: flagOn) { clear(verdict, beat) }
        }
        let delay = WatchdogLogic.nextCheckDelay(verdict, beat, nowUptimeNanos: now)
        timer.schedule(deadline: .now() + delay, leeway: .seconds(1))
    }

    private func clear(_ verdict: WatchdogVerdict, _ beat: Heartbeat?) {
        JSONFile.write(WatchdogMark(at: Date(), appPID: beat?.pid ?? 0, verdict: verdict.label), to: Paths.watchdogMark)
        Log.warn("SleepDisabled is on but the app \(verdict.label); clearing it")
        let r = FlagIO.write(false)
        if let error = r.error {
            Log.error("watchdog couldn't clear SleepDisabled: \(error)")
        } else {
            Log.info("watchdog restored sleep, read back: kernel=\(bit(r.kernel)) pmset -g=\(bit(r.pmset))")
        }
    }

    private func watch(_ pid: Int32) {
        guard pid != watchedPID else { return }
        unwatch()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            self?.unwatch()
            self?.check()
        }
        source.resume()
        exitSource = source
        watchedPID = pid
    }

    private func unwatch() {
        exitSource?.cancel()
        exitSource = nil
        watchedPID = 0
    }
}
