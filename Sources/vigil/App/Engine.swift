import AppKit
import Foundation
import VigilCore

/// The app's brain, on the main thread: holds, sensors, safety, the flag, persistence.
/// Everything is event-driven; the only clocks are a 30 s heartbeat and one timer set to the
/// next hold deadline.
final class Engine {
    private(set) var book = HoldBook()
    private(set) var settings = Settings()
    private(set) var conditions = Conditions(power: .unknown, thermal: .nominal, lowPowerMode: false, lidClosed: false)
    private(set) var decision = Decision.idle
    let flag = FlagController()
    var onChange: (() -> Void)?

    private var gate = SafetyGate()
    private var power: PowerMonitor?
    private var lid: LidMonitor?
    private var server: SocketServer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var deadlineTimer: DispatchSourceTimer?
    private var processWatches: [Int32: DispatchSourceProcess] = [:]
    private var sleepNudge: DispatchWorkItem?
    private var pendingSave: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var lastSaved: StateFile?
    private var started = false
    private(set) var shuttingDown = false

    // MARK: Lifecycle

    func start() {
        if let saved = JSONFile.read(StateFile.self, from: Paths.state) {
            settings = saved.settings
            lastSaved = saved
            if saved.bootSession == SystemInfo.bootSession, !saved.book.isEmpty {
                book = saved.book
                for hold in book.sorted where hold.pid != nil && !SystemInfo.isAlive(hold.pid!, startTime: hold.pidStartTime) {
                    book.release(id: hold.id, cause: .processExited, now: Date())
                }
                Log.info("restored \(book.count) hold(s) left by an unclean exit")
            }
        }
        conditions = Conditions(power: PowerMonitor.read(),
                                thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
                                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                lidClosed: LidMonitor.isClosed())
        // A mark from before this launch says nothing about this process.
        try? FileManager.default.removeItem(at: Paths.watchdogMark)
        // Beat before anything can touch the flag, so the watchdog never sees a change under a stale beat.
        Heartbeats.write(running: true, wantsAwake: false)
        flag.onUpdate = { [weak self] in self?.flagUpdated() }
        startSensors()
        startHeartbeat()
        let server = SocketServer(path: Paths.socket.path) { [weak self] request in
            self?.handle(request) ?? .failure("Vigil is shutting down")
        }
        do {
            try server.start()
            self.server = server
        } catch {
            Log.error("can't listen on \(Paths.socket.path): \(error)")
        }
        Log.info("Vigil \(Version.string) started (pid \(getpid())), kernel SleepDisabled=\(bit(flag.kernel))")
        started = true
        reevaluate("launch")
        flag.refreshPmset()
    }

    /// Clean exit: release everything, clear the flag synchronously and verify it.
    func shutdown(reason: String) {
        guard !shuttingDown else { return }
        shuttingDown = true
        Log.info("shutting down (\(reason))")
        server?.stop()
        heartbeatTimer?.cancel()
        deadlineTimer?.cancel()
        sleepNudge?.cancel()
        processWatches.values.forEach { $0.cancel() }
        book.releaseAll(cause: .agent, now: Date())
        pendingSave?.cancel()
        writeState(force: true)
        if flag.kernel != false || flag.target == true || flag.busy {
            let r = flag.clearSynchronously()
            if let e = r.error { Log.error("couldn't clear SleepDisabled on exit: \(e)") }
            else { Log.info("SleepDisabled=0 on exit, read back: kernel=\(bit(r.kernel)) pmset -g=\(bit(r.pmset))") }
        }
        Heartbeats.write(running: false, wantsAwake: false)
    }

    // MARK: The decision

    func reevaluate(_ why: String) {
        guard started, !shuttingDown else { return }
        let previous = decision
        let result = Policy.evaluate(book: &book, gate: &gate, conditions: conditions, settings: settings, now: Date())
        decision = result.decision
        for hold in result.expired {
            Log.info("hold ended: \(describe(hold)) (\(hold.kind == .session ? "idle too long" : "time's up"))")
        }
        for i in decision.inhibitors where !previous.inhibitors.contains(i) {
            Log.warn("safety: \(i.label)\(decision.demanded ? ", letting the Mac sleep" : "")")
        }
        for i in previous.inhibitors where !decision.inhibitors.contains(i) {
            Log.info("safety: \(i.label) cleared")
        }
        if decision.wantAwake != previous.wantAwake {
            Log.info(decision.wantAwake ? "keeping the Mac awake (\(why))" : "allowing sleep (\(why))")
            Heartbeats.write(running: true, wantsAwake: decision.wantAwake)
        }
        syncProcessWatches()
        scheduleDeadline(decision.nextCheck)
        flag.request(decision.wantAwake)
        if decision.wantAwake {
            sleepNudge?.cancel()
        } else if previous.wantAwake {
            scheduleSleepNudge()
        }
        persist()
        onChange?()
    }

    private func scheduleDeadline(_ date: Date?) {
        deadlineTimer?.cancel()
        deadlineTimer = nil
        guard let date else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Wall clock, so time asleep counts toward a timer.
        timer.schedule(wallDeadline: .now() + max(0, date.timeIntervalSinceNow) + 0.05, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.reevaluate("deadline") }
        timer.resume()
        deadlineTimer = timer
    }

    /// When the last hold goes (or safety cuts in) with the lid closed, don't count on idle sleep:
    /// other apps' assertions can block it, and the Mac would stay awake in the bag.
    private func scheduleSleepNudge() {
        sleepNudge?.cancel()
        guard settings.sleepWhenReleasedLidClosed, LidMonitor.isClosed() else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.shuttingDown, !self.decision.wantAwake, LidMonitor.isClosed(),
                  FlagIO.readKernel() == false, !Displays.hasExternal() else { return }
            Log.info("lid closed and nothing holds the Mac awake: putting it to sleep")
            FlagIO.pmsetAction("sleepnow")
        }
        sleepNudge = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    // MARK: Events

    private func startSensors() {
        let power = PowerMonitor { [weak self] snapshot in
            guard let self, snapshot != self.conditions.power else { return }
            if snapshot.onAC != self.conditions.power.onAC {
                Log.info(snapshot.onAC ? "on AC power" : "on battery (\(snapshot.batteryPercent.map { "\($0)%" } ?? "?"))")
            }
            self.conditions.power = snapshot
            self.reevaluate("power")
        }
        power.start()
        self.power = power

        let lid = LidMonitor { [weak self] closed in self?.lidChanged(closed) }
        lid.start()
        self.lid = lid

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let level = ThermalLevel(ProcessInfo.processInfo.thermalState)
            guard level != self.conditions.thermal else { return }
            Log.info("thermal state \(self.conditions.thermal.label) → \(level.label)")
            self.conditions.thermal = level
            self.reevaluate("thermal")
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let on = ProcessInfo.processInfo.isLowPowerModeEnabled
            guard on != self.conditions.lowPowerMode else { return }
            Log.info("Low Power Mode \(on ? "on" : "off")")
            self.conditions.lowPowerMode = on
            self.reevaluate("Low Power Mode")
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.info("system going to sleep (\(self.book.count) hold(s), kernel SleepDisabled=\(bit(FlagIO.readKernel())))")
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.didWake()
        })
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.beat() }
        timer.resume()
        heartbeatTimer = timer
    }

    private func beat() {
        Heartbeats.write(running: true, wantsAwake: decision.wantAwake)
        // Cheap registry reads: notice flag changes made outside Vigil, and a lid change whose
        // notification went missing.
        lidChanged(LidMonitor.isClosed())
        flag.refresh()
        for pid in processWatches.keys where !SystemInfo.isAlive(pid) { processExited(pid) }
    }

    private func didWake() {
        Heartbeats.write(running: true, wantsAwake: decision.wantAwake)
        conditions.lidClosed = LidMonitor.isClosed()
        conditions.power = PowerMonitor.read()
        conditions.thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
        Log.info("woke up (lid \(conditions.lidClosed ? "closed" : "open"), \(book.count) hold(s))")
        flag.refresh()
        reevaluate("wake")
    }

    private func lidChanged(_ closed: Bool) {
        guard closed != conditions.lidClosed else { return }
        conditions.lidClosed = closed
        let awake = decision.wantAwake && flag.kernel == true
        Log.info("lid \(closed ? "closed" : "opened")\(closed && awake ? ", staying awake" : "")")
        if closed, awake, settings.displayOffOnLidClose, !Displays.hasExternal() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.conditions.lidClosed, self.decision.wantAwake else { return }
                FlagIO.pmsetAction("displaysleepnow")
            }
        }
        reevaluate("lid")
    }

    /// Notices the flag disagreeing with what Vigil set.
    private func flagUpdated() {
        defer { onChange?() }
        guard started, !shuttingDown, !flag.busy, flag.error == nil,
              let kernel = flag.kernel, let target = flag.target, kernel != target else { return }
        if let done = flag.lastWriteFinished, Date().timeIntervalSince(done) < 5 { return }
        if target {
            if let mark = JSONFile.read(WatchdogMark.self, from: Paths.watchdogMark), Date().timeIntervalSince(mark.at) < 15 * 60 {
                try? FileManager.default.removeItem(at: Paths.watchdogMark)
                Log.warn("the watchdog cleared SleepDisabled because the app \(mark.verdict); turning it back on")
                flag.request(true)
            } else {
                // Someone ran `sudo pmset -a disablesleep 0` (the documented escape hatch): honour it.
                Log.warn("SleepDisabled was turned off outside Vigil; releasing all holds")
                letItSleep(cause: .user)
            }
        } else {
            Log.warn("SleepDisabled was turned on outside Vigil with nothing holding it; turning it off")
            flag.request(false)
        }
    }

    // MARK: Process holds

    private func syncProcessWatches() {
        let wanted = book.watchedPIDs
        for (pid, source) in processWatches where !wanted.contains(pid) {
            source.cancel()
            processWatches[pid] = nil
        }
        for pid in wanted where processWatches[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in self?.processExited(pid) }
            source.resume()
            processWatches[pid] = source
            if !SystemInfo.isAlive(pid) {
                DispatchQueue.main.async { [weak self] in self?.processExited(pid) }
            }
        }
    }

    private func processExited(_ pid: Int32) {
        processWatches.removeValue(forKey: pid)?.cancel()
        let gone = book.releaseProcess(pid: pid, now: Date())
        guard !gone.isEmpty else { return }
        for hold in gone { Log.info("hold ended: \(describe(hold)) (process \(pid) exited)") }
        reevaluate("process exited")
    }

    // MARK: Actions (menu and socket)

    @discardableResult
    func addHold(_ hold: Hold, replacing others: [String] = []) -> Hold? {
        for id in others where id != hold.id {
            if let gone = book.release(id: id, cause: .user, now: Date()) { Log.info("hold released: \(describe(gone))") }
        }
        let isNew = book.upsert(hold)
        Log.info("hold \(isNew ? "started" : "updated"): \(describe(hold))")
        reevaluate(hold.kind.rawValue + " hold")
        return book[hold.id]
    }

    @discardableResult
    func release(ids: [String], cause: ReleaseCause) -> [Hold] {
        let gone = ids.compactMap { book.release(id: $0, cause: cause, now: Date()) }
        for hold in gone { Log.info("hold released: \(describe(hold))\(cause == .user ? " by you" : "")") }
        if !gone.isEmpty { reevaluate("release") }
        return gone
    }

    /// "Let it sleep": drop every hold, and Mac mini mode too if that is what keeps it up.
    @discardableResult
    func letItSleep(cause: ReleaseCause = .user) -> [Hold] {
        let gone = book.releaseAll(cause: cause, now: Date())
        for hold in gone { Log.info("hold released: \(describe(hold))") }
        if settings.awakeOnAC, conditions.power.onAC {
            settings.awakeOnAC = false
            Log.info("Mac mini mode turned off")
        }
        reevaluate("let it sleep")
        return gone
    }

    func updateSettings(_ change: (inout Settings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        settings = s
        reevaluate("settings")
    }

    /// Fresh readings for when the menu opens.
    func refreshForDisplay() {
        conditions.thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
        conditions.power = PowerMonitor.read()
        conditions.lidClosed = LidMonitor.isClosed()
        flag.refresh()
        flag.refreshPmset()
    }

    func statusInfo() -> StatusInfo {
        StatusInfo(version: Version.string, pid: getpid(), now: Date(), wantAwake: decision.wantAwake,
                   demanded: decision.demanded, inhibitors: decision.inhibitors, flag: flag.state,
                   holds: book.sorted, conditions: conditions, settings: settings, externalDisplay: Displays.hasExternal())
    }

    // MARK: Socket requests

    func handle(_ r: Request) -> Response {
        guard !shuttingDown else { return .failure("Vigil is shutting down") }
        let now = Date()
        switch r.cmd {
        case .ping:
            return Response(ok: true, message: "pong")

        case .status:
            var response = Response(ok: true)
            response.status = statusInfo()
            return response

        case .hold:
            let reason = (r.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let source = r.source ?? "cli"
            let hold: Hold
            if let pid = r.pid {
                guard SystemInfo.isAlive(pid) else { return .failure("no process with pid \(pid)") }
                hold = Hold(id: r.id ?? HoldID.process(pid), kind: .process, reason: reason, source: source, createdAt: now,
                            expiresAt: r.seconds.map { now.addingTimeInterval($0) }, pid: pid,
                            pidStartTime: SystemInfo.startTime(pid))
            } else if let seconds = r.seconds {
                guard seconds > 0 else { return .failure("the duration must be positive") }
                hold = Hold(id: r.id ?? HoldID.random(), kind: .timed, reason: reason, source: source, createdAt: now,
                            expiresAt: now.addingTimeInterval(seconds))
            } else if r.manual == true {
                hold = Hold(id: r.id ?? HoldID.manual, kind: .manual, reason: reason, source: source, createdAt: now)
            } else {
                return .failure("a hold needs a duration, a pid, or manual")
            }
            var response = Response(ok: true)
            response.hold = addHold(hold)
            return response

        case .acquire:
            guard let sid = r.session, !sid.isEmpty else { return .failure("acquire needs a session id") }
            let key = HoldID.session(sid)
            let outcome = book.acquireSession(sid, trigger: r.trigger ?? .prompt, reason: r.reason ?? "",
                                              source: r.source ?? "cli", pid: r.pid,
                                              pidStartTime: r.pid.flatMap { SystemInfo.startTime($0) },
                                              idleTimeout: settings.sessionIdleTimeout, now: now)
            if outcome == .created, let hold = book[key] { Log.info("hold started: \(describe(hold))") }
            if outcome != .suppressed { reevaluate("session \(outcome.rawValue)") }
            var response = Response(ok: true)
            response.outcome = outcome
            response.hold = book[key]
            return response

        case .park:
            guard let sid = r.session else { return .failure("park needs a session id") }
            let pending = max(1, r.pending ?? 1)
            if book.parkSession(sid, pending: pending, now: now) {
                Log.info("turn ended with \(pending) background task(s)/cron(s) pending: still holding \(HoldID.session(sid))")
                reevaluate("session parked")
            }
            return .success

        case .release:
            var gone: [Hold] = []
            if r.all == true {
                gone = letItSleep(cause: r.cause ?? .user)
            } else if let sid = r.session {
                if let hold = book.releaseSession(sid, cause: r.cause ?? .agent, soft: r.soft ?? false, now: now) {
                    gone = [hold]
                    Log.info("hold released: \(describe(hold))")
                    reevaluate("session released")
                }
            } else {
                var ids: [String] = []
                for wanted in r.ids ?? [] {
                    if book[wanted] != nil { ids.append(wanted); continue }
                    let matches = book.holds.keys.filter { $0.hasPrefix(wanted) }
                    guard matches.count == 1 else {
                        return .failure(matches.isEmpty ? "no hold '\(wanted)'" : "'\(wanted)' matches \(matches.count) holds")
                    }
                    ids.append(matches[0])
                }
                gone = release(ids: ids, cause: r.cause ?? .user)
            }
            var response = Response(ok: true)
            response.released = gone
            return response

        case .config:
            if let key = r.key {
                if let value = r.value {
                    var s = settings
                    do { try s.set(key, to: value) } catch { return .failure("\(error)") }
                    if s != settings {
                        settings = s
                        Log.info("setting \(key) = \(settings.value(for: key) ?? value)")
                        reevaluate("settings")
                    }
                } else if settings.value(for: key) == nil {
                    return .failure(Settings.ConfigError.unknownKey(key).description)
                }
            }
            var response = Response(ok: true)
            response.settings = Dictionary(uniqueKeysWithValues: Settings.keys.map { ($0.key, settings.value(for: $0.key) ?? "") })
            return response

        case .quit:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return Response(ok: true, message: "quitting")
        }
    }

    // MARK: Persistence

    /// New or removed holds and settings are written at once; refreshes (every tool call) are
    /// coalesced into one write every few seconds.
    private func persist() {
        let file = StateFile(bootSession: SystemInfo.bootSession, settings: settings, book: book)
        guard file != lastSaved else { return }
        let structural = lastSaved.map { Set($0.book.holds.keys) != Set(file.book.holds.keys) || $0.settings != file.settings } ?? true
        if structural {
            pendingSave?.cancel()
            pendingSave = nil
            writeState(force: false)
        } else if pendingSave == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.pendingSave = nil
                self?.writeState(force: false)
            }
            pendingSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }

    private func writeState(force: Bool) {
        let file = StateFile(bootSession: SystemInfo.bootSession, settings: settings, book: book)
        guard force || file != lastSaved else { return }
        if JSONFile.write(file, to: Paths.state) { lastSaved = file }
    }
}

func describe(_ hold: Hold) -> String {
    "\(HoldText.title(hold)) [\(hold.id)]"
}
