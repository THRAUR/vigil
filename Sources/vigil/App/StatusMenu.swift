import AppKit
import VigilCore

/// The menu-bar item. Rebuilt each time it opens; while open, a 1 s timer keeps the
/// countdowns live. Nothing runs while it's closed except glyph updates on engine changes.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let engine: Engine
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var liveTimer: Timer?
    private var isOpen = false
    private var shownHoldIDs: [String] = []
    private var header: NSMenuItem?
    private var detail: NSMenuItem?
    private var holdRows: [String: NSMenuItem] = [:]
    private var timerRow: NSMenuItem?
    private var lastGlyph = ""

    init(engine: Engine) {
        self.engine = engine
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        engineChanged()
    }

    func engineChanged() {
        let s = engine.statusInfo()
        updateGlyph(s)
        guard isOpen else { return }
        if s.holds.map(\.id) != shownHoldIDs { rebuild(s) } else { refreshText(s) }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        engine.refreshForDisplay()
        rebuild(engine.statusInfo())
    }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshText(self.engine.statusInfo())
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        liveTimer?.invalidate()
        liveTimer = nil
    }

    // MARK: Glyph

    private func updateGlyph(_ s: StatusInfo) {
        let (name, description) = glyph(for: s)
        statusItem.button?.toolTip = "Vigil: " + StatusText.headline(s)
        guard name != lastGlyph else { return }
        lastGlyph = name
        let image = name == "awake-battery" ? Self.awakeOnBatteryImage()
            : NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        image?.accessibilityDescription = description
        statusItem.button?.image = image
    }

    private func glyph(for s: StatusInfo) -> (String, String) {
        if s.flag.error != nil, s.flag.target == true, s.flag.kernel != true {
            return ("exclamationmark.triangle", "Vigil can't keep the Mac awake")
        }
        if s.wantAwake {
            if s.flag.kernel != true { return ("sun.max", "Vigil: turning sleep off") }
            return s.conditions.power.onBattery ? ("awake-battery", "Vigil: awake on battery") : ("sun.max.fill", "Vigil: awake")
        }
        if s.demanded {
            if s.inhibitors.contains(.thermal) { return ("thermometer.high", "Vigil: paused, too hot") }
            if s.inhibitors.contains(.batteryFloor) { return ("battery.25percent", "Vigil: paused, battery low") }
            return ("pause.circle", "Vigil: paused")
        }
        if s.flag.kernel == true { return ("sun.max", "Vigil: letting the Mac sleep") }
        return ("moon.zzz", "Vigil: sleeping normally")
    }

    /// A sun with a small battery cut into its corner.
    static func awakeOnBatteryImage() -> NSImage? {
        guard let sun = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)),
              let battery = NSImage(systemSymbolName: "battery.50percent", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .bold)) else { return nil }
        let size = NSSize(width: sun.size.width + 5, height: max(sun.size.height, 16))
        return NSImage(size: size, flipped: false) { _ in
            sun.draw(in: NSRect(x: 0, y: (size.height - sun.size.height) / 2, width: sun.size.width, height: sun.size.height))
            let badge = NSRect(x: size.width - battery.size.width, y: 0, width: battery.size.width, height: battery.size.height)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(roundedRect: badge.insetBy(dx: -1.5, dy: -1.5), xRadius: 2, yRadius: 2).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            battery.draw(in: badge)
            return true
        }
    }

    // MARK: Building

    private func rebuild(_ s: StatusInfo) {
        menu.removeAllItems()
        holdRows.removeAll()
        shownHoldIDs = s.holds.map(\.id)

        let header = info(StatusText.headline(s))
        header.attributedTitle = NSAttributedString(string: header.title, attributes: [.font: NSFont.menuFont(ofSize: 0).bold])
        self.header = header
        menu.addItem(header)
        let detail = info(detailLine(s))
        self.detail = detail
        menu.addItem(detail)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: s.holds.isEmpty ? "No holds" : "Holding awake (\(s.holds.count))"))
        for hold in s.holds {
            let row = NSMenuItem(title: HoldText.title(hold), action: nil, keyEquivalent: "")
            row.subtitle = HoldText.detail(hold, now: s.now)
            row.image = NSImage(systemSymbolName: symbol(for: hold.kind), accessibilityDescription: nil)
            let sub = NSMenu()
            sub.autoenablesItems = false
            sub.addItem(info("\(hold.kind.rawValue) hold from \(hold.source), since \(clock(hold.createdAt))"))
            sub.addItem(info("id \(hold.id)"))
            sub.addItem(.separator())
            sub.addItem(action("Release", #selector(releaseHold(_:)), object: hold.id))
            row.submenu = sub
            holdRows[hold.id] = row
            menu.addItem(row)
        }
        if s.settings.awakeOnAC {
            menu.addItem(info(s.conditions.power.onAC ? "Mac mini mode: awake while plugged in" : "Mac mini mode: waiting for AC"))
        }

        menu.addItem(.separator())
        let manual = action("Keep Awake", #selector(toggleManual))
        manual.state = engine.book[HoldID.manual] != nil ? .on : .off
        menu.addItem(manual)

        let timers = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        let timerMenu = NSMenu()
        for (label, minutes) in [("30 Minutes", 30), ("1 Hour", 60), ("2 Hours", 120), ("4 Hours", 240)] {
            timerMenu.addItem(action(label, #selector(startTimer(_:)), object: minutes))
        }
        if engine.book[HoldID.menuTimer] != nil {
            timerMenu.addItem(.separator())
            timerMenu.addItem(action("Cancel Timer", #selector(cancelTimer)))
        }
        timers.submenu = timerMenu
        timerRow = timers
        menu.addItem(timers)

        let sleep = action("Let It Sleep", #selector(letItSleep))
        sleep.isEnabled = s.demanded
        menu.addItem(sleep)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Safety"))
        let floor = NSMenuItem(title: "Battery Floor", action: nil, keyEquivalent: "")
        floor.subtitle = s.settings.batteryFloor > 0 ? "sleep at \(s.settings.batteryFloor)% on battery" : "off"
        let floorMenu = NSMenu()
        for pct in Settings.batteryFloorChoices {
            let choice = action(pct == 0 ? "Off" : "\(pct)%", #selector(setBatteryFloor(_:)), object: pct)
            choice.state = s.settings.batteryFloor == pct ? .on : .off
            floorMenu.addItem(choice)
        }
        floor.submenu = floorMenu
        menu.addItem(floor)

        let thermal = NSMenuItem(title: "Thermal Cutoff", action: nil, keyEquivalent: "")
        thermal.subtitle = "now \(s.conditions.thermal.label), cut at \(s.settings.thermalCutoff.label)"
        let thermalMenu = NSMenu()
        for (label, level) in [("Serious (recommended)", ThermalLevel.serious), ("Critical Only", .critical)] {
            let choice = action(label, #selector(setThermalCutoff(_:)), object: level.rawValue)
            choice.state = s.settings.thermalCutoff == level ? .on : .off
            thermalMenu.addItem(choice)
        }
        thermal.submenu = thermalMenu
        menu.addItem(thermal)

        menu.addItem(toggle("Only While Plugged In", s.settings.onlyOnAC, #selector(toggleOnlyOnAC)))
        menu.addItem(toggle("Pause in Low Power Mode", s.settings.pauseInLowPowerMode, #selector(toggleLowPower)))
        menu.addItem(toggle("Display Off When Lid Closes", s.settings.displayOffOnLidClose, #selector(toggleDisplayOff)))
        menu.addItem(toggle("Sleep When Holds End, Lid Closed", s.settings.sleepWhenReleasedLidClosed, #selector(toggleLidSleep)))
        menu.addItem(toggle("Mac mini Mode (Awake on AC)", s.settings.awakeOnAC, #selector(toggleACMode)))

        menu.addItem(.separator())
        menu.addItem(toggle("Launch at Login", LaunchAgents.launchAtLogin, #selector(toggleLaunchAtLogin)))
        menu.addItem(info(hooksLine()))
        menu.addItem(action("Open Log", #selector(openLog)))
        let quit = action("Quit Vigil", #selector(quit), key: "q")
        menu.addItem(quit)
    }

    private func refreshText(_ s: StatusInfo) {
        if let header {
            header.attributedTitle = NSAttributedString(string: StatusText.headline(s), attributes: [.font: NSFont.menuFont(ofSize: 0).bold])
        }
        detail?.title = detailLine(s)
        for hold in s.holds { holdRows[hold.id]?.subtitle = HoldText.detail(hold, now: s.now) }
        timerRow?.subtitle = engine.book[HoldID.menuTimer].map { HoldText.detail($0, now: s.now) }
    }

    private func detailLine(_ s: StatusInfo) -> String {
        let p = s.conditions.power
        var parts = ["SleepDisabled \(bit(s.flag.kernel))"]
        if s.flag.pmset != nil, s.flag.pmset != s.flag.kernel { parts.append("pmset -g says \(bit(s.flag.pmset))") }
        var power = p.onAC ? "AC" : "Battery"
        if let pct = p.batteryPercent { power += " \(pct)%" }
        parts.append(power)
        parts.append("thermal \(s.conditions.thermal.label)")
        parts.append("lid \(s.conditions.lidClosed ? "closed" : "open")")
        if s.conditions.lowPowerMode { parts.append("Low Power Mode") }
        return parts.joined(separator: " · ")
    }

    private func hooksLine() -> String {
        guard let text = try? String(contentsOf: Paths.claudeSettings, encoding: .utf8),
              let json = try? JSONParser.parse(text) else { return "Claude Code hooks: not installed" }
        let n = ClaudeHooks.installedEvents(in: json).count
        return n == ClaudeHooks.specs.count ? "Claude Code hooks: installed"
            : n == 0 ? "Claude Code hooks: not installed (vigil install-hooks)" : "Claude Code hooks: partial (vigil install-hooks)"
    }

    private func symbol(for kind: HoldKind) -> String {
        switch kind {
        case .manual: return "hand.raised"
        case .timed: return "timer"
        case .process: return "gearshape"
        case .session: return "sparkles"
        }
    }

    private func clock(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }

    // MARK: Item helpers

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, object: Any? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.representedObject = object
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ selector: Selector) -> NSMenuItem {
        let item = action(title, selector)
        item.state = on ? .on : .off
        return item
    }

    // MARK: Actions

    @objc private func toggleManual() {
        if engine.book[HoldID.manual] != nil {
            engine.release(ids: [HoldID.manual], cause: .user)
        } else {
            engine.addHold(Hold(id: HoldID.manual, kind: .manual, reason: "Keep Awake", source: "menu", createdAt: Date()),
                           replacing: [HoldID.menuTimer])
        }
    }

    @objc private func startTimer(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        let now = Date()
        engine.addHold(Hold(id: HoldID.menuTimer, kind: .timed, reason: "Timer (\(DurationText.format(Double(minutes) * 60)))",
                            source: "menu", createdAt: now, expiresAt: now.addingTimeInterval(Double(minutes) * 60)),
                       replacing: [HoldID.manual])
    }

    @objc private func cancelTimer() { engine.release(ids: [HoldID.menuTimer], cause: .user) }

    @objc private func releaseHold(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        engine.release(ids: [id], cause: .user)
    }

    @objc private func letItSleep() { engine.letItSleep() }

    @objc private func setBatteryFloor(_ sender: NSMenuItem) {
        guard let pct = sender.representedObject as? Int else { return }
        engine.updateSettings { $0.batteryFloor = pct }
        Log.info("setting battery-floor = \(pct == 0 ? "off" : "\(pct)%")")
    }

    @objc private func setThermalCutoff(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let level = ThermalLevel(rawValue: raw) else { return }
        engine.updateSettings { $0.thermalCutoff = level }
        Log.info("setting thermal-cutoff = \(level.label)")
    }

    @objc private func toggleOnlyOnAC() { engine.updateSettings { $0.onlyOnAC.toggle() } }
    @objc private func toggleLowPower() { engine.updateSettings { $0.pauseInLowPowerMode.toggle() } }
    @objc private func toggleDisplayOff() { engine.updateSettings { $0.displayOffOnLidClose.toggle() } }
    @objc private func toggleLidSleep() { engine.updateSettings { $0.sleepWhenReleasedLidClosed.toggle() } }
    @objc private func toggleACMode() { engine.updateSettings { $0.awakeOnAC.toggle() } }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAgents.setLaunchAtLogin(!LaunchAgents.launchAtLogin)
            Log.info("launch at login \(LaunchAgents.launchAtLogin ? "on" : "off")")
        } catch {
            Log.error("couldn't change launch at login: \(error.localizedDescription)")
        }
    }

    @objc private func openLog() { NSWorkspace.shared.open(Paths.log) }

    @objc private func quit() { NSApp.terminate(nil) }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
