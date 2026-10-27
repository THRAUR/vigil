import Foundation
import VigilCore

/// Owns every write to SleepDisabled. Writes run one at a time on a serial queue and always end
/// with a read-back; the observed values live on the main thread for the UI.
final class FlagController {
    private let queue = DispatchQueue(label: "vigil.flag", qos: .userInitiated)
    private(set) var target: Bool?
    private(set) var kernel: Bool?
    private(set) var pmset: Bool?
    private(set) var error: String?
    private(set) var busy = false
    private(set) var verifiedAt: Date?
    private(set) var lastWriteFinished: Date?
    private var failedTarget: Bool?
    private var retryWork: DispatchWorkItem?
    private var retryDelay: TimeInterval = 15
    /// Main thread, after each write or refresh.
    var onUpdate: (() -> Void)?

    init() {
        kernel = FlagIO.readKernel()
        rearmCrashGuard()
    }

    var state: FlagState {
        FlagState(kernel: kernel, pmset: pmset, target: target, busy: busy, error: error, verifiedAt: verifiedAt)
    }

    /// Ask for the flag to be `on`. A no-op if the kernel already agrees.
    func request(_ on: Bool) {
        let changed = target != on
        target = on
        if changed { failedTarget = nil }
        pump()
    }

    /// Re-read the kernel value. No process is spawned, so this is fine every heartbeat.
    func refresh() {
        kernel = FlagIO.readKernel()
        rearmCrashGuard()
        onUpdate?()
    }

    /// Re-read `pmset -g` in the background (for the menu).
    func refreshPmset() {
        queue.async { [weak self] in
            let value = FlagIO.readPmset()
            DispatchQueue.main.async {
                self?.pmset = value
                self?.onUpdate?()
            }
        }
    }

    /// For shutdown: waits for any write in flight, then clears the flag and verifies it.
    func clearSynchronously() -> FlagIO.WriteResult {
        retryWork?.cancel()
        target = false
        let result = queue.sync { FlagIO.write(false) }
        kernel = result.kernel
        pmset = result.pmset
        error = result.error
        rearmCrashGuard()
        return result
    }

    private func pump() {
        guard !busy, let want = target else { return }
        if kernel == want, error == nil { return }
        if failedTarget == want { return } // the retry timer will try again
        busy = true
        retryWork?.cancel()
        if want { CrashGuard.armed = 1 }
        queue.async { [weak self] in
            let result = FlagIO.write(want)
            DispatchQueue.main.async { self?.finish(want, result) }
        }
    }

    private func finish(_ want: Bool, _ r: FlagIO.WriteResult) {
        busy = false
        lastWriteFinished = Date()
        kernel = r.kernel
        pmset = r.pmset
        error = r.error
        if let e = r.error {
            failedTarget = want
            Log.error("couldn't set SleepDisabled=\(want ? 1 : 0): \(e)")
            scheduleRetry()
        } else {
            failedTarget = nil
            verifiedAt = Date()
            retryDelay = 15
            Log.info("SleepDisabled=\(want ? 1 : 0), read back: kernel=\(bit(r.kernel)) pmset -g=\(bit(r.pmset))")
        }
        rearmCrashGuard()
        if target != want { pump() }
        onUpdate?()
    }

    private func scheduleRetry() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 300)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.busy else { return }
            self.failedTarget = nil
            self.error = nil
            self.pump()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func rearmCrashGuard() {
        CrashGuard.armed = (kernel ?? true) || target == true || busy ? 1 : 0
    }
}

func bit(_ b: Bool?) -> String { b.map { $0 ? "1" : "0" } ?? "?" }
