import Darwin
import Foundation
import VigilCore

/// `vigil acquire --hook` / `vigil release --hook`, run by Claude Code for each hook event.
/// The event in the stdin JSON decides what happens. Never prints to stdout (UserPromptSubmit
/// would add it to the prompt), never blocks the agent, always exits 0. Never starts the app
/// either: if you quit Vigil, it stays quit (launchd still restarts it after a crash).
enum Hook {
    static func run(fallback: HookAction) -> Int32 {
        guard let input = readInput() else {
            Log.warn("hook: no hook JSON on stdin")
            return 0
        }
        guard let sid = input.sessionID else {
            Log.warn("hook \(input.event ?? "?"): no session_id")
            return 0
        }
        let action = input.event == nil ? fallback : HookPolicy.action(for: input)
        var request: Request
        switch action {
        case .ignore:
            return 0
        case .acquire(let trigger):
            request = Request(.acquire)
            request.trigger = trigger
            request.reason = input.holdReason
            request.source = "claude"
            request.pid = SystemInfo.ancestor(named: ["claude"])
        case .park(let pending):
            request = Request(.park)
            request.pending = pending
        case .release(let soft):
            request = Request(.release)
            request.soft = soft
            request.cause = .agent
        }
        request.session = sid
        do {
            let r = try SocketClient.send(request, timeout: 4)
            if !r.ok { Log.warn("hook \(input.event ?? "?"): \(r.error ?? "failed")") }
        } catch SocketClient.Failure.notRunning {
            if input.event == "UserPromptSubmit" { Log.info("Vigil isn't running, so this Claude turn won't keep the Mac awake") }
        } catch {
            Log.warn("hook \(input.event ?? "?"): \(error)")
        }
        return 0
    }

    /// Reads stdin to EOF (so Claude Code never sees a broken pipe), keeping the first 2 MB.
    static func readInput() -> HookInput? {
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        let keep = 2 << 20
        var data = Data()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let deadline = Date().addingTimeInterval(3)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let ready = poll(&pfd, 1, Int32(remaining * 1000))
            if ready < 0 { if errno == EINTR { continue } else { break } }
            if ready == 0 { break }
            let n = read(STDIN_FILENO, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            total += n
            if data.count < keep { data.append(contentsOf: buffer[0..<min(n, keep - data.count)]) }
        }
        return total <= keep ? HookInput.parse(data) : HookInput.scan(data)
    }
}
