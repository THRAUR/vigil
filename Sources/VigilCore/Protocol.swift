import Foundation

/// One line of JSON from the CLI to the app over the Unix socket.
public struct Request: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable {
        case ping, status, hold, acquire, park, release, config, quit
    }

    public var cmd: Command
    public var id: String?
    public var ids: [String]?
    public var reason: String?
    public var source: String?
    /// `hold`: duration in seconds (a timed hold, or a cap on a process hold).
    public var seconds: Double?
    public var pid: Int32?
    public var pidStartTime: Double?
    /// `hold`: no duration and no pid, held until released.
    public var manual: Bool?
    public var session: String?
    public var trigger: AcquireTrigger?
    public var pending: Int?
    public var all: Bool?
    public var cause: ReleaseCause?
    public var soft: Bool?
    public var key: String?
    public var value: String?

    public init(_ cmd: Command) { self.cmd = cmd }
}

public struct Response: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var message: String?
    public var hold: Hold?
    public var released: [Hold]?
    public var outcome: AcquireOutcome?
    public var status: StatusInfo?
    public var settings: [String: String]?

    public init(ok: Bool, error: String? = nil, message: String? = nil) {
        self.ok = ok
        self.error = error
        self.message = message
    }

    public static func failure(_ error: String) -> Response { Response(ok: false, error: error) }
    public static let success = Response(ok: true)
}

public struct FlagState: Codable, Sendable, Equatable {
    /// What the kernel reports (IOPMrootDomain SleepDisabled). This is what actually blocks sleep.
    public var kernel: Bool?
    /// What `pmset -g` reported after Vigil's last write.
    public var pmset: Bool?
    public var target: Bool?
    public var busy: Bool
    public var error: String?
    public var verifiedAt: Date?

    public init(kernel: Bool?, pmset: Bool?, target: Bool?, busy: Bool, error: String?, verifiedAt: Date?) {
        self.kernel = kernel
        self.pmset = pmset
        self.target = target
        self.busy = busy
        self.error = error
        self.verifiedAt = verifiedAt
    }
}

public struct StatusInfo: Codable, Sendable {
    public var version: String
    public var pid: Int32
    public var now: Date
    public var wantAwake: Bool
    public var demanded: Bool
    public var inhibitors: [Inhibitor]
    public var flag: FlagState
    public var holds: [Hold]
    public var conditions: Conditions
    public var settings: Settings
    public var externalDisplay: Bool

    public init(version: String, pid: Int32, now: Date, wantAwake: Bool, demanded: Bool,
                inhibitors: [Inhibitor], flag: FlagState, holds: [Hold], conditions: Conditions,
                settings: Settings, externalDisplay: Bool) {
        self.version = version
        self.pid = pid
        self.now = now
        self.wantAwake = wantAwake
        self.demanded = demanded
        self.inhibitors = inhibitors
        self.flag = flag
        self.holds = holds
        self.conditions = conditions
        self.settings = settings
        self.externalDisplay = externalDisplay
    }
}

public enum Wire {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
