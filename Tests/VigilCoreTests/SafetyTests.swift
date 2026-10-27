import Foundation
import Testing
@testable import VigilCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func conditions(ac: Bool = true, pct: Int? = 80, thermal: ThermalLevel = .nominal,
                        lpm: Bool = false, lid: Bool = false) -> Conditions {
    Conditions(power: PowerSnapshot(onAC: ac, hasBattery: true, batteryPercent: pct, isCharging: ac),
               thermal: thermal, lowPowerMode: lpm, lidClosed: lid)
}

/// Runs the gate and returns its inhibitors (keeps mutating calls out of #expect).
private func inhibitors(_ gate: inout SafetyGate, _ c: Conditions, _ s: Settings = Settings(), at: Date = t0) -> [Inhibitor] {
    gate.evaluate(c, s, now: at).inhibitors
}

private func decide(_ book: inout HoldBook, _ gate: inout SafetyGate, _ c: Conditions,
                    _ s: Settings = Settings(), at: Date = t0) -> (decision: Decision, expired: [Hold]) {
    Policy.evaluate(book: &book, gate: &gate, conditions: c, settings: s, now: at)
}

@Suite struct Thermal {
    @Test func seriousTripsAndCoolsDownWithHysteresis() {
        var gate = SafetyGate()
        let a = inhibitors(&gate, conditions(thermal: .fair))
        let b = inhibitors(&gate, conditions(thermal: .serious))
        #expect(a.isEmpty && b == [.thermal])
        // Cooler, but not for long enough yet.
        let r1 = gate.evaluate(conditions(thermal: .fair), Settings(), now: t0.addingTimeInterval(10))
        #expect(r1.inhibitors == [.thermal])
        #expect(r1.recheckAt == t0.addingTimeInterval(10 + SafetyGate.thermalCooldown))
        // Heats up again: the cooldown restarts.
        let c = inhibitors(&gate, conditions(thermal: .serious), at: t0.addingTimeInterval(60))
        _ = inhibitors(&gate, conditions(thermal: .nominal), at: t0.addingTimeInterval(100))
        let d = inhibitors(&gate, conditions(thermal: .nominal), at: t0.addingTimeInterval(219))
        #expect(c == [.thermal] && d == [.thermal])
        let r2 = gate.evaluate(conditions(thermal: .nominal), Settings(), now: t0.addingTimeInterval(220))
        #expect(r2.inhibitors.isEmpty)
        #expect(r2.recheckAt == nil)
    }

    @Test func criticalOnlyIgnoresSerious() {
        var gate = SafetyGate()
        var s = Settings()
        s.thermalCutoff = .critical
        let serious = inhibitors(&gate, conditions(thermal: .serious), s)
        let critical = inhibitors(&gate, conditions(thermal: .critical), s)
        #expect(serious.isEmpty && critical == [.thermal])
    }
}

@Suite struct Battery {
    @Test func floorTripsOnBatteryOnly() {
        var gate = SafetyGate()
        let onAC = inhibitors(&gate, conditions(ac: true, pct: 10))
        let above = inhibitors(&gate, conditions(ac: false, pct: 21))
        let at = inhibitors(&gate, conditions(ac: false, pct: 20))
        #expect(onAC.isEmpty && above.isEmpty && at == [.batteryFloor])
    }

    @Test func hysteresisAvoidsFlapping() {
        var gate = SafetyGate()
        _ = inhibitors(&gate, conditions(ac: false, pct: 20))
        let stillLow = inhibitors(&gate, conditions(ac: false, pct: 21))
        let recovered = inhibitors(&gate, conditions(ac: false, pct: 22))
        #expect(stillLow == [.batteryFloor] && recovered.isEmpty)
    }

    @Test func pluggingInClearsTheFloor() {
        var gate = SafetyGate()
        _ = inhibitors(&gate, conditions(ac: false, pct: 15))
        let plugged = inhibitors(&gate, conditions(ac: true, pct: 15))
        #expect(plugged.isEmpty)
    }

    @Test func floorOffNeverTrips() {
        var gate = SafetyGate()
        var s = Settings()
        s.batteryFloor = 0
        let r = inhibitors(&gate, conditions(ac: false, pct: 3), s)
        #expect(r.isEmpty)
    }

    @Test func unknownPercentKeepsState() {
        var gate = SafetyGate()
        _ = inhibitors(&gate, conditions(ac: false, pct: 10))
        let r = inhibitors(&gate, conditions(ac: false, pct: nil))
        #expect(r == [.batteryFloor])
    }

    @Test func desktopWithoutBatteryIsNeverOnBattery() {
        var gate = SafetyGate()
        var s = Settings()
        s.onlyOnAC = true
        let c = Conditions(power: PowerSnapshot(onAC: false, hasBattery: false, batteryPercent: nil, isCharging: false),
                           thermal: .nominal, lowPowerMode: false, lidClosed: false)
        let r = inhibitors(&gate, c, s)
        #expect(r.isEmpty)
    }
}

@Suite struct Switches {
    @Test func onlyOnAC() {
        var gate = SafetyGate()
        var s = Settings()
        s.onlyOnAC = true
        let battery = inhibitors(&gate, conditions(ac: false, pct: 90), s)
        let plugged = inhibitors(&gate, conditions(ac: true), s)
        #expect(battery == [.notOnAC] && plugged.isEmpty)
    }

    @Test func lowPowerMode() {
        var gate = SafetyGate()
        var s = Settings()
        let paused = inhibitors(&gate, conditions(lpm: true), s)
        s.pauseInLowPowerMode = false
        let ignored = inhibitors(&gate, conditions(lpm: true), s)
        #expect(paused == [.lowPowerMode] && ignored.isEmpty)
    }

    @Test func severalAtOnce() {
        var gate = SafetyGate()
        var s = Settings()
        s.onlyOnAC = true
        let r = inhibitors(&gate, conditions(ac: false, pct: 5, thermal: .critical, lpm: true), s)
        #expect(r == [.thermal, .batteryFloor, .notOnAC, .lowPowerMode])
    }
}

@Suite struct PolicyDecision {
    @Test func noHoldsMeansSleep() {
        var book = HoldBook(), gate = SafetyGate()
        let d = decide(&book, &gate, conditions()).decision
        #expect(!d.demanded && !d.wantAwake)
    }

    @Test func holdWantsAwakeUnlessInhibited() {
        var book = HoldBook(), gate = SafetyGate()
        book.upsert(Hold(id: "m", kind: .manual, reason: "", source: "t", createdAt: t0))
        let cool = decide(&book, &gate, conditions()).decision
        let hot = decide(&book, &gate, conditions(thermal: .serious)).decision
        #expect(cool.wantAwake)
        #expect(hot.demanded && !hot.wantAwake && hot.inhibitors == [.thermal])
        // Holds survive a safety pause.
        #expect(book.count == 1)
    }

    @Test func expiryHappensDuringEvaluation() {
        var book = HoldBook(), gate = SafetyGate()
        book.upsert(Hold(id: "t", kind: .timed, reason: "", source: "t", createdAt: t0, expiresAt: t0.addingTimeInterval(60)))
        let early = decide(&book, &gate, conditions())
        #expect(early.decision.wantAwake && early.decision.nextCheck == t0.addingTimeInterval(60))
        let late = decide(&book, &gate, conditions(), at: t0.addingTimeInterval(61))
        #expect(!late.decision.wantAwake && late.expired.map(\.id) == ["t"])
    }

    @Test func macMiniModeOnACOnly() {
        var book = HoldBook(), gate = SafetyGate()
        var s = Settings()
        s.awakeOnAC = true
        let plugged = decide(&book, &gate, conditions(ac: true), s).decision
        let battery = decide(&book, &gate, conditions(ac: false), s).decision
        #expect(plugged.wantAwake && !battery.demanded)
    }

    @Test func nextCheckIncludesThermalCooldown() {
        var book = HoldBook(), gate = SafetyGate()
        book.upsert(Hold(id: "t", kind: .timed, reason: "", source: "t", createdAt: t0, expiresAt: t0.addingTimeInterval(3600)))
        _ = decide(&book, &gate, conditions(thermal: .critical))
        let d = decide(&book, &gate, conditions()).decision
        #expect(d.nextCheck == t0.addingTimeInterval(SafetyGate.thermalCooldown))
    }
}
