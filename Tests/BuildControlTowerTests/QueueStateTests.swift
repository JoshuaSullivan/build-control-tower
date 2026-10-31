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

    // MARK: - Priority pre-emption

    private func priorityTicket(_ agent: String) -> BuildTicket {
        BuildTicket(
            id: UUID(),
            agent: agent,
            task: "build \(agent)",
            requestedAt: .zero,
            isPriority: true
        )
    }

    private let yieldDeadline: Duration = .seconds(180)

    /// Grant `a` the slot, then have priority ticket `p` arrive and reconcile.
    private func stateWithPriorityArrival(
        _ a: BuildTicket,
        _ p: BuildTicket,
        buildActive: Bool
    ) -> QueueState {
        var state = QueueState()
        state.enqueue(a)
        state.reconcile(now: .zero, buildActive: false, grace: grace)
        state.enqueue(p)
        state.reconcile(
            now: .seconds(10),
            buildActive: buildActive,
            grace: grace,
            yieldDeadline: yieldDeadline
        )
        return state
    }

    @Test func priorityTakesSlotImmediatelyWhenNothingIsBuilding() {
        let a = ticket("a")
        let p = priorityTicket("p")

        // No build CPU: the holder isn't really building, so there is nothing to
        // interrupt and the handoff can be instant.
        let state = stateWithPriorityArrival(a, p, buildActive: false)

        #expect(state.disposition(of: p.id) == .granted)
        // The displaced ticket lands directly behind the build that took its
        // slot, not at the back of the line.
        #expect(state.disposition(of: a.id) == .preempted(position: 1))
    }

    @Test func priorityAsksRunningBuildToYieldRatherThanSeizingIt() {
        let a = ticket("a")
        let p = priorityTicket("p")

        // A real build is burning CPU, so the holder keeps the slot for now and
        // is merely asked to stand down.
        let state = stateWithPriorityArrival(a, p, buildActive: true)

        #expect(state.disposition(of: a.id) == .yieldRequested)
        #expect(state.disposition(of: p.id) == .queued(position: 1))
        #expect(state.active?.yieldRequestedAt == .seconds(10))
    }

    @Test func yieldingHolderHandsOverOnRelease() {
        let a = ticket("a")
        let p = priorityTicket("p")
        var state = stateWithPriorityArrival(a, p, buildActive: true)

        // The agent notices at its next check-in, kills the build, releases.
        state.release(a.id)
        state.reconcile(
            now: .seconds(30),
            buildActive: false,
            grace: grace,
            yieldDeadline: yieldDeadline
        )

        #expect(state.disposition(of: p.id) == .granted)
        #expect(state.disposition(of: a.id) == .unknown)
    }

    @Test func slotIsSeizedOnceTheYieldDeadlinePasses() {
        let a = ticket("a")
        let p = priorityTicket("p")
        var state = stateWithPriorityArrival(a, p, buildActive: true)

        // The holder keeps heartbeating but never releases. Still building, so
        // the stale-grant reclaim can never fire — only the yield deadline can.
        state.touch(a.id, now: .seconds(150))
        state.reconcile(
            now: .seconds(190),
            buildActive: true,
            grace: grace,
            yieldDeadline: yieldDeadline
        )

        #expect(state.disposition(of: p.id) == .granted)
        #expect(state.disposition(of: a.id) == .preempted(position: 1))
    }

    @Test func grantIsNotSeizedBeforeTheYieldDeadline() {
        let a = ticket("a")
        let p = priorityTicket("p")
        var state = stateWithPriorityArrival(a, p, buildActive: true)

        // One second short of the deadline: the holder still has time to comply.
        state.reconcile(
            now: .seconds(189),
            buildActive: true,
            grace: grace,
            yieldDeadline: yieldDeadline
        )

        #expect(state.disposition(of: a.id) == .yieldRequested)
        #expect(state.disposition(of: p.id) == .queued(position: 1))
    }

    @Test func cancelledPriorityRequestStandsTheHolderBackDown() {
        let a = ticket("a")
        let p = priorityTicket("p")
        var state = stateWithPriorityArrival(a, p, buildActive: true)
        #expect(state.disposition(of: a.id) == .yieldRequested)

        // The priority agent gives up before the holder ever complied. Killing a
        // healthy build for a request that no longer exists would be pure waste.
        state.release(p.id)
        state.reconcile(
            now: .seconds(400),
            buildActive: true,
            grace: grace,
            yieldDeadline: yieldDeadline
        )

        #expect(state.disposition(of: a.id) == .granted)
        #expect(state.active?.yieldRequestedAt == nil)
    }

    @Test func priorityOverridesTheExternalBuildGuard() {
        var state = QueueState()
        let p = priorityTicket("p")
        state.enqueue(p)

        // A manual Xcode build is burning CPU and owns no ticket, so nothing can
        // be asked to yield. A human asked for this build now, so grant it.
        state.reconcile(
            now: .zero,
            buildActive: true,
            grace: grace,
            yieldDeadline: yieldDeadline
        )

        #expect(state.disposition(of: p.id) == .granted)
    }

    @Test func normalRequestStillWaitsForAnExternalBuild() {
        var state = QueueState()
        let a = ticket("a")
        state.enqueue(a)

        state.reconcile(
            now: .zero,
            buildActive: true,
            grace: grace,
            yieldDeadline: yieldDeadline
        )

        #expect(state.disposition(of: a.id) == .queued(position: 1))
    }

    @Test func priorityGrantIsNotItselfPreempted() {
        let a = ticket("a")
        let first = priorityTicket("first")
        var state = stateWithPriorityArrival(a, first, buildActive: false)
        #expect(state.disposition(of: first.id) == .granted)

        // A second priority request waits its turn instead of starting a chain of
        // interruptions that discards more work at every link.
        let second = priorityTicket("second")
        state.enqueue(second)
        state.reconcile(
            now: .seconds(400),
            buildActive: true,
            grace: grace,
            yieldDeadline: yieldDeadline
        )

        #expect(state.disposition(of: first.id) == .granted)
        #expect(state.active?.yieldRequestedAt == nil)
        #expect(state.disposition(of: second.id) == .queued(position: 2))
    }

    @Test func waitingLineOrdersPreemptedThenPriorityThenNormal() {
        let a = ticket("a")
        let p = priorityTicket("p")
        var state = stateWithPriorityArrival(a, p, buildActive: false)

        // `a` was pre-empted and sits at the head. A later priority request goes
        // behind it but ahead of normal work, whenever that normal work arrived.
        let normal = ticket("normal")
        let later = priorityTicket("later")
        state.enqueue(normal)
        state.enqueue(later)

        #expect(state.waiting.map(\.agent) == ["a", "later", "normal"])
    }

    @Test func normalRequestsKeepArrivalOrderAmongThemselves() {
        var state = QueueState()
        let a = ticket("a")
        let b = ticket("b")
        let c = ticket("c")
        state.enqueue(a)
        state.enqueue(b)
        state.enqueue(c)

        #expect(state.waiting.map(\.agent) == ["a", "b", "c"])
    }

    @Test func preemptedTicketIsReGrantedFirstOnceThePriorityBuildFinishes() {
        let a = ticket("a")
        let p = priorityTicket("p")
        var state = stateWithPriorityArrival(a, p, buildActive: false)
        state.enqueue(ticket("later"))

        state.release(p.id)
        state.reconcile(
            now: .seconds(50),
            buildActive: false,
            grace: grace,
            yieldDeadline: yieldDeadline
        )

        #expect(state.disposition(of: a.id) == .granted)
    }

    @Test func acknowledgingPreemptionQuietsTheAlarmButKeepsThePlace() {
        let a = ticket("a")
        let p = priorityTicket("p")
        var state = stateWithPriorityArrival(a, p, buildActive: false)
        #expect(state.disposition(of: a.id) == .preempted(position: 1))

        // Told once, in a reply the agent asked for. Repeating it for the rest of
        // an ordinary wait would just be shouting at an agent that already
        // stopped — but it must not cost the ticket its head-of-line place.
        state.acknowledgePreemption(a.id)
        state.enqueue(ticket("later"))

        #expect(state.disposition(of: a.id) == .queued(position: 1))
        #expect(state.waiting.map(\.agent) == ["a", "later"])
    }

    @Test func promoteMovesAWaitingTicketAheadOfNormalWork() {
        var state = QueueState()
        let a = ticket("a")
        let b = ticket("b")
        let c = ticket("c")
        state.enqueue(a)
        state.enqueue(b)
        state.enqueue(c)
        state.reconcile(now: .zero, buildActive: false, grace: grace)

        // The monitor's "promote" on the build sitting last in line.
        let promoted = state.promote(c.id)

        #expect(promoted)
        #expect(state.waiting.map(\.agent) == ["c", "b"])
    }

    @Test func promoteThenReconcilePreemptsTheRunningBuild() {
        var state = QueueState()
        let a = ticket("a")
        let b = ticket("b")
        state.enqueue(a)
        state.enqueue(b)
        state.reconcile(now: .zero, buildActive: false, grace: grace)

        state.promote(b.id)
        state.reconcile(
            now: .seconds(10),
            buildActive: false,
            grace: grace,
            yieldDeadline: yieldDeadline
        )

        #expect(state.disposition(of: b.id) == .granted)
        #expect(state.disposition(of: a.id) == .preempted(position: 1))
    }

    @Test func promotingAnUnknownOrActiveTicketDoesNothing() {
        var state = QueueState()
        let a = ticket("a")
        state.enqueue(a)
        state.reconcile(now: .zero, buildActive: false, grace: grace)

        // The active build is already at the front of everything; there is no
        // queue position to promote it past.
        #expect(state.promote(a.id) == false)
        #expect(state.promote(UUID()) == false)
        #expect(state.disposition(of: a.id) == .granted)
    }

    @Test func staleGrantIsStillReclaimedWithoutRequeueing() {
        var state = QueueState()
        let a = ticket("a")
        let p = priorityTicket("p")
        state.enqueue(a)
        state.reconcile(now: .zero, buildActive: false, grace: grace)
        state.enqueue(p)

        // Silent past grace with no build CPU: the agent is presumed crashed, so
        // its ticket is dropped outright rather than re-queued as pre-empted.
        state.reconcile(
            now: .seconds(301),
            buildActive: false,
            grace: grace,
            yieldDeadline: yieldDeadline
        )

        #expect(state.disposition(of: p.id) == .granted)
        #expect(state.disposition(of: a.id) == .unknown)
    }
}
