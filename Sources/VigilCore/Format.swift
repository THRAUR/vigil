import Foundation

public enum HoldText {
    public static func title(_ h: Hold) -> String {
        if !h.reason.isEmpty { return h.reason }
        switch h.kind {
        case .manual: return "Keep awake"
        case .timed: return "Timer"
        case .process: return "pid \(h.pid ?? 0)"
        case .session: return "Agent session"
        }
    }

    public static func detail(_ h: Hold, now: Date) -> String {
        var parts: [String] = []
        switch h.kind {
        case .manual:
            parts.append(h.expiresAt == nil ? "until you release it" : left(h.expiresAt!, now))
        case .timed:
            parts.append(h.expiresAt.map { left($0, now) } ?? "timed")
        case .process:
            parts.append("until pid \(h.pid.map(String.init) ?? "?") exits")
            if let e = h.expiresAt { parts.append("at most " + left(e, now)) }
        case .session:
            if let pending = h.parkedOnBackground, pending > 0 {
                parts.append("waiting on \(pending) background task\(pending == 1 ? "" : "s")")
            } else if let seen = h.lastSeen {
                let ago = now.timeIntervalSince(seen)
                parts.append(ago < 5 ? "active now" : "active \(DurationText.format(ago)) ago")
            }
            if let idle = h.idleTimeout, idle > 0 { parts.append("auto-release after \(DurationText.format(idle)) idle") }
        }
        return parts.joined(separator: " · ")
    }

    static func left(_ date: Date, _ now: Date) -> String {
        DurationText.format(max(0, date.timeIntervalSince(now))) + " left"
    }
}

public enum StatusText {
    /// One-line headline shared by the menu and `vigil status`.
    public static func headline(_ s: StatusInfo) -> String {
        if let error = s.flag.error, s.flag.target == true, s.flag.kernel != true {
            return "Can't keep awake: \(error)"
        }
        if s.flag.kernel == true && !s.wantAwake && s.flag.busy { return "Letting the Mac sleep…" }
        if s.wantAwake {
            if s.flag.kernel == true {
                return s.conditions.power.onBattery ? "Awake on battery, lid can close" : "Awake, lid can close"
            }
            return "Turning sleep off…"
        }
        if s.demanded {
            let why = s.inhibitors.map(\.label).joined(separator: ", ")
            return "Paused (\(why)): the Mac may sleep"
        }
        return "Sleeping normally"
    }

    public static func render(_ s: StatusInfo) -> String {
        var lines: [String] = []
        lines.append("Vigil \(s.version): \(headline(s))")

        let p = s.conditions.power
        var power = p.onAC ? "AC" : "battery"
        if let pct = p.batteryPercent { power += " \(pct)%" + (p.isCharging ? " charging" : "") }
        power += s.settings.batteryFloor > 0 ? " · floor \(s.settings.batteryFloor)%" : " · floor off"
        if s.settings.onlyOnAC { power += " · only on AC" }
        if s.settings.awakeOnAC { power += " · Mac mini mode" }
        lines.append("  Power    \(power)")

        var env = "\(s.conditions.thermal.label) (cutoff \(s.settings.thermalCutoff.label))"
        env += " · lid \(s.conditions.lidClosed ? "closed" : "open")"
        env += s.conditions.lowPowerMode ? " · Low Power Mode on" : ""
        if s.externalDisplay { env += " · external display" }
        lines.append("  Thermal  \(env)")

        var flag = "SleepDisabled kernel=\(bit(s.flag.kernel)) pmset=\(bit(s.flag.pmset))"
        if let t = s.flag.target { flag += " target=\(t ? 1 : 0)" }
        if let v = s.flag.verifiedAt { flag += " · verified \(DurationText.format(s.now.timeIntervalSince(v))) ago" }
        if let e = s.flag.error { flag += " · error: \(e)" }
        lines.append("  Flag     \(flag)")

        if s.holds.isEmpty {
            lines.append("  Holds    none")
        } else {
            lines.append("  Holds (\(s.holds.count))")
            let width = min(28, s.holds.map { $0.id.count }.max() ?? 0)
            for h in s.holds {
                let id = h.id.count > width ? String(h.id.prefix(width - 1)) + "…" : h.id.padding(toLength: width, withPad: " ", startingAt: 0)
                lines.append("    \(id)  \(HoldText.title(h)): \(HoldText.detail(h, now: s.now))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func bit(_ b: Bool?) -> String { b.map { $0 ? "1" : "0" } ?? "?" }
}
