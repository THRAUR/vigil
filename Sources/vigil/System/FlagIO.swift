import Foundation
import IOKit
import VigilCore

/// The one mechanism that survives a closed lid on Apple Silicon: the kernel's SleepDisabled flag,
/// set with `pmset -a disablesleep 1|0` through the narrow sudoers rule the installer adds.
enum FlagIO {
    struct WriteResult {
        var kernel: Bool?
        var pmset: Bool?
        var error: String?
    }

    static func rootDomain() -> io_service_t {
        IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    }

    static func rootDomainBool(_ key: String) -> Bool? {
        let root = rootDomain()
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }

    /// Test mode: a file holding "1" or "0" stands in for the kernel flag; sudo and pmset never run.
    static let fakeFlag = ProcessInfo.processInfo.environment["VIGIL_FAKE_FLAG"]
    static var isFake: Bool { fakeFlag != nil }

    private static func readFake() -> Bool {
        (try? String(contentsOfFile: fakeFlag!, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// The live kernel value (IOPMrootDomain "SleepDisabled"). Cheap: no process is spawned.
    static func readKernel() -> Bool? { isFake ? readFake() : rootDomainBool("SleepDisabled") }

    /// What `pmset -g` reports, the source of truth the requirements name.
    static func readPmset() -> Bool? {
        if isFake { return readFake() }
        let r = Shell.run("/usr/bin/pmset", ["-g"], timeout: 5)
        guard r.ok else { return nil }
        return PmsetOutput.sleepDisabled(in: r.output)
    }

    /// Sets the flag, then reads it back from both the kernel and `pmset -g`.
    static func write(_ on: Bool) -> WriteResult {
        if isFake {
            try? (on ? "1" : "0").write(toFile: fakeFlag!, atomically: true, encoding: .utf8)
            return WriteResult(kernel: readFake(), pmset: readFake(), error: nil)
        }
        let r = Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"], timeout: 15)
        var error: String?
        if r.timedOut {
            error = "sudo pmset timed out"
        } else if r.status != 0 {
            error = SudoError.describe(status: r.status, output: r.output)
        }
        // powerd applies the setting asynchronously; give the kernel a moment to catch up.
        var kernel = readKernel()
        let deadline = Date().addingTimeInterval(2)
        while error == nil, kernel != on, Date() < deadline {
            usleep(100_000)
            kernel = readKernel()
        }
        let pmset = readPmset()
        if error == nil, kernel != on || pmset != on {
            error = "asked for SleepDisabled=\(on ? 1 : 0) but kernel=\(bit(kernel)) pmset=\(bit(pmset))"
        }
        return WriteResult(kernel: kernel, pmset: pmset, error: error)
    }

    /// `pmset displaysleepnow` / `sleepnow`. These need no root; in test mode they are only logged.
    static func pmsetAction(_ action: String) {
        if isFake {
            Log.info("(test mode) would run pmset \(action)")
            return
        }
        Shell.runDetached("/usr/bin/pmset", [action])
    }
}
