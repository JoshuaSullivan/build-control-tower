import Foundation
import Testing

@testable import BuildControlTower

/// Tests for the `BuildQueue` actor — the layer between the pure `QueueState`
/// and the outside world.
///
/// `QueueStateTests` proves the transition rules; these prove the *wiring*: that
/// a tool call reaches the right transition, that the pre-emption alarm is
/// raised exactly once to the agent that needs it, and that `promote` behaves as
/// the `/promote` endpoint needs it to. A stub probe stands in for `ps`, so the
/// "is a build running?" signal is exact rather than whatever the host machine
/// happens to be doing.
struct BuildQueueTests {
    /// A probe with a fixed answer, so tests pick which pre-emption path runs.
    private struct StubProbe: BuildProbe {
        let active: Bool
        func buildActivityDetected() async -> Bool { active }
    }

    /// A probe whose answer can change mid-test, to model a build ramping up
    /// CPU after its slot was granted.
    private actor MutableProbe: BuildProbe {
        private var active: Bool
        init(active: Bool) { self.active = active }
        func set(_ value: Bool) { active = value }
        func buildActivityDetected() async -> Bool { active }
    }

    private func config(yieldSeconds: Int = 180) -> Configuration {
        Configuration(
            pollInterval: .seconds(120),
            staleGrantGrace: .seconds(360),
            cpuThresholdPercent: 40,
            yieldDeadline: .seconds(yieldSeconds),
            port: 7373
        )
    }

    private func makeQueue(buildActive: Bool = false, yieldSeconds: Int = 180) -> BuildQueue {
        BuildQueue(probe: StubProbe(active: buildActive), config: config(yieldSeconds: yieldSeconds))
    }

    @Test func priorityRequestTakesTheSlotFromAnIdleHolder() async {
        let queue = makeQueue()
        let holder = await queue.request(agent: "A", task: "build")
        #expect(holder.disposition == .granted)

        let priority = await queue.request(agent: "P", task: "urgent", priority: true)

        #expect(priority.disposition == .granted)
        // The displaced agent is told, once, that it must stop.
        #expect(await queue.status(of: holder.id) == .preempted(position: 1))
    }

    @Test func preemptionAlarmIsRaisedOnceThenTheTicketWaitsNormally() async {
        let queue = makeQueue()
        let holder = await queue.request(agent: "A", task: "build")
        _ = await queue.request(agent: "P", task: "urgent", priority: true)

        #expect(await queue.status(of: holder.id) == .preempted(position: 1))
        // Repeating the alarm for the rest of an ordinary wait would just be
        // shouting at an agent that already stopped.
        #expect(await queue.status(of: holder.id) == .queued(position: 1))
    }

    @Test func aHeartbeatIsHowABuildingAgentLearnsItWasPreempted() async {
        let queue = makeQueue()
        let holder = await queue.request(agent: "A", task: "build")
        _ = await queue.heartbeat(holder.id, progress: 40)
        _ = await queue.request(agent: "P", task: "urgent", priority: true)

        let (disposition, progress) = await queue.heartbeat(holder.id, progress: 60)

        #expect(disposition == .preempted(position: 1))
        // The progress belongs to whoever holds the slot; a pre-empted agent
        // must not be handed the priority build's number.
        #expect(progress == nil)
    }

    @Test func aRunningBuildIsAskedToYieldRatherThanCutOff() async {
        let probe = MutableProbe(active: false)
        let queue = BuildQueue(probe: probe, config: config())
        let holder = await queue.request(agent: "A", task: "build")
        #expect(holder.disposition == .granted)

        // The build ramps up and is now clearly burning CPU.
        await probe.set(true)
        let priority = await queue.request(agent: "P", task: "urgent", priority: true)

        // The tower cannot interrupt the agent, so it asks rather than seizes.
        #expect(priority.disposition == .queued(position: 1))
        #expect(await queue.status(of: holder.id) == .yieldRequested)
    }

    @Test func aYieldingHolderKeepsItsProgressUntilItReleases() async {
        let probe = MutableProbe(active: false)
        let queue = BuildQueue(probe: probe, config: config())
        let holder = await queue.request(agent: "A", task: "build")
        await probe.set(true)
        _ = await queue.request(agent: "P", task: "urgent", priority: true)

        let (disposition, progress) = await queue.heartbeat(holder.id, progress: 75)

        // It still holds the slot, so its own estimate is still its own — the
        // heartbeat is a stop instruction, not a repossession.
        #expect(disposition == .yieldRequested)
        #expect(progress == 75)
    }

    @Test func yieldingHolderHandsOverTheSlotOnFinish() async {
        let probe = MutableProbe(active: false)
        let queue = BuildQueue(probe: probe, config: config())
        let holder = await queue.request(agent: "A", task: "build")
        await probe.set(true)
        let priority = await queue.request(agent: "P", task: "urgent", priority: true)
        #expect(await queue.status(of: holder.id) == .yieldRequested)

        // The agent complies: kills its build, releases the ticket. The priority
        // build is granted even though CPU is still winding down, because a
        // priority ticket overrides the external-build guard.
        #expect(await queue.finish(holder.id))

        #expect(await queue.status(of: priority.id) == .granted)
    }

    @Test func abandonedPriorityRequestStandsTheHolderBackDown() async {
        let probe = MutableProbe(active: false)
        let queue = BuildQueue(probe: probe, config: config())
        let holder = await queue.request(agent: "A", task: "build")
        await probe.set(true)
        let priority = await queue.request(agent: "P", task: "urgent", priority: true)
        #expect(await queue.status(of: holder.id) == .yieldRequested)

        // The priority agent gives up before the holder ever complied. Killing a
        // healthy build for a request that no longer exists would be pure waste.
        #expect(await queue.finish(priority.id))

        #expect(await queue.status(of: holder.id) == .granted)
    }

    @Test func externalBuildStillWithholdsANormalGrant() async {
        let queue = makeQueue(buildActive: true)

        let waiter = await queue.request(agent: "A", task: "build")

        #expect(waiter.disposition == .queued(position: 1))
    }

    @Test func priorityOverridesAnExternalBuild() async {
        let queue = makeQueue(buildActive: true)

        // A manual Xcode build owns no ticket, so nothing can be asked to yield;
        // the human asked for this build now, so it goes.
        let priority = await queue.request(agent: "P", task: "urgent", priority: true)

        #expect(priority.disposition == .granted)
    }

    @Test func promoteRaisesAWaitingTicketAndReturnsTheQueue() async {
        let queue = makeQueue()
        let holder = await queue.request(agent: "A", task: "build")
        let waiter = await queue.request(agent: "B", task: "later")
        #expect(waiter.disposition == .queued(position: 1))

        let snapshot = await queue.promote(waiter.id)

        #expect(snapshot?.active?.id == waiter.id)
        #expect(snapshot?.active?.priority == true)
        #expect(await queue.status(of: holder.id) == .preempted(position: 1))
    }

    @Test func promotingAnUnknownTicketReportsNothingToPromote() async {
        let queue = makeQueue()
        _ = await queue.request(agent: "A", task: "build")

        // The `/promote` endpoint turns this into a 404.
        #expect(await queue.promote(UUID()) == nil)
    }

    @Test func promotingTheActiveBuildReportsNothingToPromote() async {
        let queue = makeQueue()
        let holder = await queue.request(agent: "A", task: "build")

        // It is already at the front of everything; there is no position to
        // promote it past, and marking it priority would only make it immune to
        // pre-emption after the fact.
        #expect(await queue.promote(holder.id) == nil)
    }

    @Test func finishingThePriorityBuildHandsTheSlotBackToThePreemptedAgent() async {
        let queue = makeQueue()
        let holder = await queue.request(agent: "A", task: "build")
        let priority = await queue.request(agent: "P", task: "urgent", priority: true)
        _ = await queue.request(agent: "C", task: "unrelated")

        #expect(await queue.finish(priority.id))

        // The interrupted build resumes before unrelated work that was queued
        // behind it, so the pre-emption costs it its turn and nothing more.
        #expect(await queue.status(of: holder.id) == .granted)
    }

    @Test func snapshotSurfacesPriorityForAMonitor() async {
        let queue = makeQueue()
        _ = await queue.request(agent: "A", task: "build")
        _ = await queue.request(agent: "P", task: "urgent", priority: true)

        let snapshot = await queue.snapshot()

        #expect(snapshot.active?.agent == "P")
        #expect(snapshot.active?.priority == true)
        #expect(snapshot.waiting.first?.agent == "A")
        #expect(snapshot.waiting.first?.preempted == true)
    }
}
