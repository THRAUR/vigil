import AppKit
import VigilCore

enum AppMain {
    static func run() -> Never {
        Log.role = "app"
        Paths.ensureDirectories()
        guard SingleInstance.acquire() else {
            Log.info("another Vigil is already running; this copy exits")
            exit(0)
        }
        CrashGuard.install()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: Engine?
    private var statusMenu: StatusMenu?
    private var activity: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opt out of App Nap so the heartbeat and timers stay on time; this doesn't block idle sleep.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Vigil heartbeat and hold timers")
        let engine = Engine()
        let menu = StatusMenu(engine: engine)
        engine.onChange = { [weak menu] in menu?.engineChanged() }
        self.engine = engine
        statusMenu = menu
        engine.start()

        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.engine?.shutdown(reason: "signal \(sig)")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.shutdown(reason: "quit")
    }
}
