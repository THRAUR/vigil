import Darwin
import Foundation
import VigilCore

enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Wire.decoder().decode(T.self, from: data)
    }

    /// Atomic replace (write a temp file, rename), private to the user.
    @discardableResult
    static func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            let enc = Wire.encoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(value).write(to: url, options: .atomic)
            chmod(url.path, 0o600)
            return true
        } catch {
            Log.warn("couldn't write \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }
}

/// What the app persists. Holds only come back after a crash within the same boot: a clean quit
/// clears them, and a reboot invalidates them.
struct StateFile: Codable, Equatable {
    var version = 1
    var bootSession: String
    var settings: Settings
    var book: HoldBook
}

enum SingleInstance {
    private static var fd: Int32 = -1

    /// Takes an exclusive lock for the app's lifetime. False if another instance holds it.
    static func acquire() -> Bool {
        let f = open(Paths.lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard f >= 0 else { return true }
        if flock(f, LOCK_EX | LOCK_NB) != 0 {
            close(f)
            return false
        }
        fd = f
        return true
    }
}

enum Heartbeats {
    static func write(running: Bool, wantsAwake: Bool) {
        let pid = getpid()
        let hb = Heartbeat(pid: pid, pidStartTime: SystemInfo.startTime(pid) ?? 0, uptimeNanos: SystemInfo.uptimeNanos(),
                           bootSession: SystemInfo.bootSession, wall: Date(), running: running, wantsAwake: wantsAwake)
        JSONFile.write(hb, to: Paths.heartbeat)
    }

    static func read() -> Heartbeat? { JSONFile.read(Heartbeat.self, from: Paths.heartbeat) }
}
