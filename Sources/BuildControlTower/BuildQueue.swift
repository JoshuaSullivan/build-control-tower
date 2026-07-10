import Foundation

/// Serializes builds across agents. Owns the `QueueState`, the system probe,
/// and a monotonic clock, and drives the state machine on every request,
/// release, and background poll tick.
///
/// This is the only place `QueueState` is mutated, so the actor boundary is
/// what actually enforces the "one build at a time" invariant across the
/// concurrent tool calls arriving over the MCP transport.
actor BuildQueue {
    private var state = QueueState()
    private let probe: BuildProbe
    private let config: Configuration
    private let clock: ContinuousClock
    private let startInstant: ContinuousClock.Instant

    init(probe: BuildProbe, config: Configuration) {
        let clock = ContinuousClock()
        self.clock = clock
        self.startInstant = clock.now
        self.probe = probe
        self.config = config
    }

    /// Enqueue a new request and immediately try to advance the queue (fast
    /// path). Returns the minted ticket id and where it landed.
    func request(agent: String?) async -> (id: UUID, disposition: BuildDisposition) {
        let ticket = BuildTicket(id: UUID(), agent: agent, requestedAt: uptime())
        state.enqueue(ticket)
        await reconcile()
        return (ticket.id, state.disposition(of: ticket.id))
    }

    /// Re-check a ticket. Also drives a reconcile so that an actively polling
    /// agent helps advance the queue (e.g. picks up promptly once an external
    /// build clears), rather than waiting for the slow background poll.
    func status(of id: UUID) async -> BuildDisposition {
        await reconcile()
        return state.disposition(of: id)
    }

    /// Release whatever slot the ticket holds and advance the queue. This is
    /// the fast path that keeps throughput high between queued agents.
    /// Returns `true` if the ticket actually held a place.
    @discardableResult
    func finish(_ id: UUID) async -> Bool {
        let held = state.release(id)
        await reconcile()
        return held
    }

    /// A human-readable snapshot of the queue.
    func snapshot() -> QueueSnapshot {
        QueueSnapshot(
            active: state.active.map { ActiveEntry(id: $0.ticket.id, agent: $0.ticket.agent) },
            waiting: state.waiting.map { WaitingEntry(id: $0.id, agent: $0.agent) }
        )
    }

    /// The background safety-net loop: reconciles on the slow cadence to cover
    /// crashed agents (stale-grant reclaim) and externally-started builds
    /// (external-build guard). Runs until its task is cancelled at shutdown.
    func runPollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: config.pollInterval)
            await reconcile()
        }
    }

    /// One reconcile pass: sample the probe, then run the pure transition.
    private func reconcile() async {
        let buildActive = await probe.buildActivityDetected()
        state.reconcile(now: uptime(), buildActive: buildActive, grace: config.staleGrantGrace)
    }

    /// Elapsed time since the server started.
    private func uptime() -> Duration {
        startInstant.duration(to: clock.now)
    }
}
