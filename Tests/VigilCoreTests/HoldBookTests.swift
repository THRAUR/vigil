import Foundation
import Testing
@testable import VigilCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func timed(_ id: String, minutes: Double, at now: Date = t0) -> Hold {
    Hold(id: id, kind: .timed, reason: id, source: "test", createdAt: now, expiresAt: now.addingTimeInterval(minutes * 60))
}

// swift-testing can't evaluate mutating calls inside #expect, so results are bound first.

@Suite struct HoldRefcount {
    @Test func flagStaysOnUntilLastHoldGoes() {
        var book = HoldBook()
        book.upsert(Hold(id: HoldID.manual, kind: .manual, reason: "", source: "menu", createdAt: t0))
        book.upsert(timed("render", minutes: 30))
        #expect(book.count == 2)
        book.release(id: HoldID.manual, cause: .user, now: t0)
        #expect(!book.isEmpty)
        book.release(id: "render", cause: .user, now: t0)
        #expect(book.isEmpty)
    }

    @Test func upsertSameIDDoesNotStack() {
        var book = HoldBook()
        let first = book.upsert(timed("a", minutes: 10))
        let second = book.upsert(timed("a", minutes: 20, at: t0.addingTimeInterval(60)))
        #expect(first && !second)
        #expect(book.count == 1)
        // Keeps the original creation time, takes the new deadline.
        #expect(book["a"]?.createdAt == t0)
        #expect(book["a"]?.expiresAt == t0.addingTimeInterval(60 + 20 * 60))
        book.release(id: "a", cause: .user, now: t0)
        #expect(book.isEmpty)
    }

    @Test func releasingUnknownIDIsHarmless() {
        var book = HoldBook()
        let a = book.release(id: "nope", cause: .user, now: t0)
        let b = book.releaseSession("nope", cause: .agent, now: t0)
        #expect(a == nil && b == nil)
    }

    @Test func releaseAllReturnsEverything() {
        var book = HoldBook()
        book.upsert(timed("a", minutes: 10))
        book.upsert(timed("b", minutes: 10))
        let gone = book.releaseAll(cause: .user, now: t0)
        #expect(gone.map(\.id) == ["a", "b"])
        #expect(book.isEmpty)
    }
}

@Suite struct HoldExpiry {
    @Test func timedHoldExpiresAtDeadline() {
        var book = HoldBook()
        book.upsert(timed("a", minutes: 30))
        let early = book.expire(now: t0.addingTimeInterval(29 * 60))
        #expect(early.isEmpty)
        #expect(book.nextDeadline() == t0.addingTimeInterval(30 * 60))
        let due = book.expire(now: t0.addingTimeInterval(30 * 60))
        #expect(due.map(\.id) == ["a"])
        #expect(book.isEmpty)
        #expect(book.nextDeadline() == nil)
    }

    @Test func nextDeadlineIsTheEarliest() {
        var book = HoldBook()
        book.upsert(timed("late", minutes: 60))
        book.upsert(timed("soon", minutes: 5))
        book.upsert(Hold(id: "m", kind: .manual, reason: "", source: "t", createdAt: t0))
        #expect(book.nextDeadline() == t0.addingTimeInterval(5 * 60))
    }

    @Test func manualAndProcessHoldsNeverExpireWithoutCap() {
        var book = HoldBook()
        book.upsert(Hold(id: "m", kind: .manual, reason: "", source: "t", createdAt: t0))
        book.upsert(Hold(id: "p", kind: .process, reason: "", source: "t", createdAt: t0, pid: 42))
        let gone = book.expire(now: t0.addingTimeInterval(86400 * 30))
        #expect(gone.isEmpty)
    }

    @Test func processHoldCapApplies() {
        var book = HoldBook()
        book.upsert(Hold(id: "p", kind: .process, reason: "", source: "t", createdAt: t0,
                         expiresAt: t0.addingTimeInterval(3600), pid: 42))
        let gone = book.expire(now: t0.addingTimeInterval(3600))
        #expect(gone.map(\.id) == ["p"])
    }

    @Test func processExitReleasesEveryHoldOnThatPID() {
        var book = HoldBook()
        book.upsert(Hold(id: "p", kind: .process, reason: "", source: "t", createdAt: t0, pid: 42))
        _ = book.acquireSession("s1", trigger: .prompt, reason: "", source: "claude", pid: 42, pidStartTime: nil, idleTimeout: 600, now: t0)
        book.upsert(Hold(id: "q", kind: .process, reason: "", source: "t", createdAt: t0, pid: 43))
        #expect(book.watchedPIDs == [42, 43])
        let gone = book.releaseProcess(pid: 42, now: t0)
        #expect(Set(gone.map(\.id)) == ["p", "session:s1"])
        #expect(book.holds.keys.sorted() == ["q"])
    }
}

@Suite struct SessionHolds {
    func acquire(_ book: inout HoldBook, _ trigger: AcquireTrigger, at: Date = t0, idle: TimeInterval = 3600) -> AcquireOutcome {
        book.acquireSession("abc", trigger: trigger, reason: "Claude · proj", source: "claude",
                            pid: nil, pidStartTime: nil, idleTimeout: idle, now: at)
    }

    @Test func promptCreatesAndActivityRefreshes() {
        var book = HoldBook()
        let a = acquire(&book, .prompt)
        let b = acquire(&book, .activity, at: t0.addingTimeInterval(600))
        #expect(a == .created && b == .refreshed)
        #expect(book.count == 1)
        #expect(book["session:abc"]?.lastSeen == t0.addingTimeInterval(600))
        #expect(book["session:abc"]?.createdAt == t0)
    }

    @Test func secondPromptAfterInterruptStillNeedsOneRelease() {
        // Esc skips Stop, so the next prompt acquires again without a release in between.
        var book = HoldBook()
        _ = acquire(&book, .prompt)
        _ = acquire(&book, .prompt, at: t0.addingTimeInterval(30))
        book.releaseSession("abc", cause: .agent, now: t0.addingTimeInterval(60))
        #expect(book.isEmpty)
    }

    @Test func idleSessionExpires() {
        var book = HoldBook()
        _ = acquire(&book, .prompt, idle: 1800)
        _ = acquire(&book, .activity, at: t0.addingTimeInterval(1000), idle: 1800)
        #expect(book.nextDeadline() == t0.addingTimeInterval(2800))
        let early = book.expire(now: t0.addingTimeInterval(2799))
        let due = book.expire(now: t0.addingTimeInterval(2800))
        #expect(early.isEmpty && due.count == 1)
    }

    @Test func activityRecreatesAfterAgentRelease() {
        // A turn started without UserPromptSubmit still gets a hold on its first tool call.
        var book = HoldBook()
        _ = acquire(&book, .prompt)
        book.releaseSession("abc", cause: .agent, now: t0)
        let outcome = acquire(&book, .activity)
        #expect(outcome == .created)
    }

    @Test func userReleaseIsNotUndoneByToolActivity() {
        var book = HoldBook()
        _ = acquire(&book, .prompt)
        book.releaseAll(cause: .user, now: t0)
        let blocked = acquire(&book, .activity)
        #expect(blocked == .suppressed)
        #expect(book.isEmpty)
        // A new prompt is the user asking again.
        let again = acquire(&book, .prompt)
        #expect(again == .created)
        book.releaseSession("abc", cause: .agent, now: t0)
        let afterAgent = acquire(&book, .activity)
        #expect(afterAgent == .created)
    }

    @Test func refreshNeverCreates() {
        var book = HoldBook()
        let none = acquire(&book, .refresh)
        _ = acquire(&book, .prompt)
        let some = acquire(&book, .refresh)
        #expect(none == .suppressed && some == .refreshed)
    }

    @Test func parkedSessionIgnoresSoftRelease() {
        var book = HoldBook()
        _ = acquire(&book, .prompt)
        let parked = book.parkSession("abc", pending: 2, now: t0.addingTimeInterval(5))
        let soft = book.releaseSession("abc", cause: .agent, soft: true, now: t0)
        #expect(parked && soft == nil)
        #expect(book.count == 1)
        // The next turn unparks it, then a soft release works again.
        _ = acquire(&book, .prompt, at: t0.addingTimeInterval(100))
        #expect(book["session:abc"]?.parkedOnBackground == nil)
        let later = book.releaseSession("abc", cause: .agent, soft: true, now: t0)
        #expect(later != nil)
    }

    @Test func parkedSessionStillHonoursHardReleaseAndIdle() {
        var book = HoldBook()
        _ = acquire(&book, .prompt, idle: 600)
        book.parkSession("abc", pending: 1, now: t0.addingTimeInterval(100))
        #expect(book.nextDeadline() == t0.addingTimeInterval(700))
        let hard = book.releaseSession("abc", cause: .agent, soft: false, now: t0)
        let parkGone = book.parkSession("abc", pending: 1, now: t0)
        #expect(hard != nil && !parkGone)
    }

    @Test func roundTripsThroughJSON() throws {
        var book = HoldBook()
        _ = acquire(&book, .prompt)
        book.upsert(timed("t", minutes: 5))
        book.releaseSession("abc", cause: .user, now: t0)
        let data = try Wire.encoder().encode(book)
        let back = try Wire.decoder().decode(HoldBook.self, from: data)
        #expect(back == book)
        #expect(back.userReleasedSessions["abc"] != nil)
    }
}
