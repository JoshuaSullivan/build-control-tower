import Foundation
import Testing

@testable import BuildControlTower

/// Tests for the pure queue state machine. Because `QueueState` takes time and
/// the "build active" signal as plain parameters, every advancement rule from
/// the tech spec is exercised deterministically here — no clock, no processes.
struct QueueStateTests {
    private func ticket(_ agent: String) -> BuildTicket {
        BuildTicket(id: UUID(), agent: agent, requestedAt: .zero)
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
}
