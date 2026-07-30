import Foundation
import Testing

@testable import BuildControlTower

/// Tests for the pure queue state machine. Because `QueueState` takes time and
/// the "build active" signal as plain parameters, every advancement rule from
/// the tech spec is exercised deterministically here — no clock, no processes.
struct QueueStateTests {
    private func ticket(_ agent: String) -> BuildTicket {
        BuildTicket(id: UUID(), agent: agent, task: "build \(agent)", requestedAt: .zero)
    }

    private let grace: Duration = .seconds(300)

    @Test func grantsHeadWhenIdleAndNothingBuilding() {
        var state = QueueState()
        let a = ticket("a")
        state.enqueue(a)

        state.reconcile(now: .zero, buildActive: false, grace: grace)

        #expect(state.disposition(of: a.id) == .granted)
    }

    @Test func onlyOneGrantAtATime() {
        var state = QueueState()
        let a = ticket("a")
        let b = ticket("b")
        state.enqueue(a)
        state.enqueue(b)

        state.reconcile(now: .zero, buildActive: false, grace: grace)

        #expect(state.disposition(of: a.id) == .granted)
        #expect(state.disposition(of: b.id) == .queued(position: 1))
    }

    @Test func externalBuildWithholdsGrant() {
        var state = QueueState()
        let a = ticket("a")
        state.enqueue(a)

        // A build is burning CPU that isn't ours — do not grant.
        state.reconcile(now: .zero, buildActive: true, grace: grace)

        #expect(state.disposition(of: a.id) == .queued(position: 1))
    }

    @Test func releaseAdvancesToNextImmediately() {
        var state = QueueState()
        let a = ticket("a")
        let b = ticket("b")
        state.enqueue(a)
        state.enqueue(b)
        state.reconcile(now: .zero, buildActive: false, grace: grace)

        state.release(a.id)
        state.reconcile(now: .seconds(5), buildActive: false, grace: grace)

        #expect(state.disposition(of: a.id) == .unknown)
        #expect(state.disposition(of: b.id) == .granted)
    }

    @Test func grantIsNotReclaimedBeforeGraceWindow() {
        var state = QueueState()
        let a = ticket("a")
        state.enqueue(a)
        state.reconcile(now: .zero, buildActive: false, grace: grace)

        // Well within grace, still no CPU (build hasn't ramped up yet).
        state.reconcile(now: .seconds(100), buildActive: false, grace: grace)

        #expect(state.disposition(of: a.id) == .granted)
    }

    @Test func silentGrantIsReclaimedAfterGraceAndAdvances() {
        var state = QueueState()
        let a = ticket("a")
        let b = ticket("b")
        state.enqueue(a)
        state.enqueue(b)
        state.reconcile(now: .zero, buildActive: false, grace: grace)

        // Past grace with no build CPU: agent presumed dead. Reclaim and advance.
        state.reconcile(now: .seconds(301), buildActive: false, grace: grace)

        #expect(state.disposition(of: a.id) == .unknown)
        #expect(state.disposition(of: b.id) == .granted)
    }

    @Test func busyGrantIsNotReclaimedEvenPastGrace() {
        var state = QueueState()
        let a = ticket("a")
        state.enqueue(a)
        state.reconcile(now: .zero, buildActive: false, grace: grace)

        // Past grace, but a build is clearly running — it's the grantee's build.
        state.reconcile(now: .seconds(600), buildActive: true, grace: grace)

        #expect(state.disposition(of: a.id) == .granted)
    }

    @Test func dispositionIsUnknownForStrangerTicket() {
        let state = QueueState()
        #expect(state.disposition(of: UUID()) == .unknown)
    }

    // MARK: - Heartbeats

    @Test func heartbeatExtendsGrantPastOriginalGrace() {
        var state = QueueState()
        let a = ticket("a")
        let b = ticket("b")
        state.enqueue(a)
        state.enqueue(b)
        state.reconcile(now: .zero, buildActive: false, grace: grace)

        // A check-in inside the window resets the silence clock, so a build that
        // is quiet but alive keeps its slot well past the original deadline.
        state.touch(a.id, now: .seconds(250))
        state.reconcile(now: .seconds(400), buildActive: false, grace: grace)

        #expect(state.disposition(of: a.id) == .granted)
        #expect(state.disposition(of: b.id) == .queued(position: 1))
    }

    @Test func grantIsReclaimedOnceHeartbeatsStop() {
        var state = QueueState()
        let a = ticket("a")
        let b = ticket("b")
        state.enqueue(a)
        state.enqueue(b)
        state.reconcile(now: .zero, buildActive: false, grace: grace)
        state.touch(a.id, now: .seconds(250))

        // Silence for a full grace window *after* the last heartbeat.
        state.reconcile(now: .seconds(551), buildActive: false, grace: grace)

        #expect(state.disposition(of: a.id) == .unknown)
        #expect(state.disposition(of: b.id) == .granted)
    }

    @Test func heartbeatOnWaitingTicketIsIgnored() {
        var state = QueueState()
        let a = ticket("a")
        let b = ticket("b")
        state.enqueue(a)
        state.enqueue(b)
        state.reconcile(now: .zero, buildActive: false, grace: grace)

        // Only a grant can be kept alive; a queued ticket has nothing to extend.
        let accepted = state.touch(b.id, now: .seconds(250), progress: 50)

        #expect(accepted == false)
        #expect(state.disposition(of: b.id) == .queued(position: 1))
        #expect(state.active?.lastSeen == .zero)
        #expect(state.active?.progress == nil)
    }

    @Test func heartbeatRecordsAndClampsProgress() {
        var state = QueueState()
        let a = ticket("a")
        state.enqueue(a)
        state.reconcile(now: .zero, buildActive: false, grace: grace)

        state.touch(a.id, now: .seconds(10), progress: 45)
        #expect(state.active?.progress == 45)

        // Nonsense estimates are pinned to the reportable range, not rejected.
        state.touch(a.id, now: .seconds(20), progress: -5)
        #expect(state.active?.progress == 0)

        state.touch(a.id, now: .seconds(30), progress: 150)
        #expect(state.active?.progress == 100)
    }

    @Test func heartbeatWithoutProgressKeepsLastEstimate() {
        var state = QueueState()
        let a = ticket("a")
        state.enqueue(a)
        state.reconcile(now: .zero, buildActive: false, grace: grace)
        state.touch(a.id, now: .seconds(10), progress: 70)

        // An agent that can't estimate this time shouldn't erase what it knew.
        state.touch(a.id, now: .seconds(20))

        #expect(state.active?.progress == 70)
        #expect(state.active?.lastSeen == .seconds(20))
    }

    @Test func progressDoesNotCarryToNextGrantee() {
        var state = QueueState()
        let a = ticket("a")
        let b = ticket("b")
        state.enqueue(a)
        state.enqueue(b)
        state.reconcile(now: .zero, buildActive: false, grace: grace)
        state.touch(a.id, now: .seconds(10), progress: 80)

        state.release(a.id)
        state.reconcile(now: .seconds(11), buildActive: false, grace: grace)

        #expect(state.disposition(of: b.id) == .granted)
        #expect(state.active?.progress == nil)
        #expect(state.active?.grantedAt == .seconds(11))
    }
}
