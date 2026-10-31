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

    /// How often a building agent should send `build_heartbeat`, quoted to the
    /// agent when its slot is granted so the advice stays honest whatever
    /// `BCT_GRACE_SECONDS` this daemon was launched with.
    var recommendedHeartbeatInterval: Duration { config.recommendedHeartbeatInterval }

    /// How long a pre-empted build has to stand down before its slot is taken,
    /// quoted to the agent that is asked to yield.
    var yieldDeadline: Duration { config.yieldDeadline }

    /// Enqueue a new request and immediately try to advance the queue (fast
    /// path). Returns the minted ticket id and where it landed.
    ///
    /// - Parameter priority: when `true`, the request jumps ahead of normal
    ///   waiters and pre-empts a running normal build. Reserved for builds a
    ///   human has explicitly asked to run now.
    func request(
        agent: String?,
        task: String?,
        priority: Bool = false
    ) async -> (id: UUID, disposition: BuildDisposition) {
        let ticket = BuildTicket(
            id: UUID(),
            agent: agent,
            task: task,
            requestedAt: uptime(),
            isPriority: priority
        )
        state.enqueue(ticket)
        await reconcile()
        return (ticket.id, state.disposition(of: ticket.id))
    }

    /// Raise a waiting ticket to priority on a human's behalf — the operation
    /// behind the monitor's `POST /promote`.
    ///
    /// - Returns: `nil` if no waiting ticket carries that id (unknown, already
    ///   finished, or already holding the slot), otherwise the queue as it
    ///   stands once the promotion has been reconciled.
    func promote(_ id: UUID) async -> QueueSnapshot? {
        guard state.promote(id) else { return nil }
        await reconcile()
        return snapshot()
    }

    /// Re-check a ticket. Also drives a reconcile so that an actively polling
    /// agent helps advance the queue (e.g. picks up promptly once an external
    /// build clears), rather than waiting for the slow background poll.
    ///
    /// The poll doubles as a sign of life: any call naming a ticket proves its
    /// owner is still around, so a granted agent that polls instead of using
    /// `heartbeat` is never reclaimed out from under itself.
    func status(of id: UUID) async -> BuildDisposition {
        state.touch(id, now: uptime())
        await reconcile()
        return report(id)
    }

    /// Record that a building agent is still alive, with its optional estimate
    /// of how far along the build is.
    ///
    /// - Returns: where the ticket now stands — so an agent that already lost its
    ///   grant finds out on its next check-in — along with the progress the tower
    ///   now holds for it, which is the clamped estimate just reported or the
    ///   previous one if this beat carried no number.
    func heartbeat(_ id: UUID, progress: Int?) async -> (disposition: BuildDisposition, progress: Int?) {
        // Touch before reconciling: the reconcile this call drives must never
        // reclaim the very ticket that just proved it is alive.
        state.touch(id, now: uptime(), progress: progress)
        await reconcile()

        let disposition = report(id)
        // Only report progress back if this ticket still owns the slot; otherwise
        // `active` describes some other agent's build.
        let holdsSlot = disposition == .granted || disposition == .yieldRequested
        return (disposition, holdsSlot ? state.active?.progress : nil)
    }

    /// Read a ticket's standing and consume its pre-emption marker.
    ///
    /// The marker exists to raise the alarm exactly once, in a reply the agent
    /// is guaranteed to see because it asked for it. Leaving it set would make
    /// every later poll of a perfectly ordinary wait shout "stop building" at an
    /// agent that already has.
    private func report(_ id: UUID) -> BuildDisposition {
        let disposition = state.disposition(of: id)
        if case .preempted = disposition {
            state.acknowledgePreemption(id)
        }
        return disposition
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
        let now = uptime()
        return QueueSnapshot(
            active: state.active.map {
                ActiveEntry(
                    id: $0.ticket.id,
                    agent: $0.ticket.agent,
                    task: $0.ticket.task,
                    progress: $0.progress,
                    elapsedSeconds: Self.seconds(now - $0.grantedAt),
                    secondsSinceHeartbeat: Self.seconds(now - $0.lastSeen),
                    priority: $0.ticket.isPriority,
                    yieldRequestedSecondsAgo: $0.yieldRequestedAt.map { Self.seconds(now - $0) }
                )
            },
            waiting: state.waiting.map {
                WaitingEntry(
                    id: $0.id,
                    agent: $0.agent,
                    task: $0.task,
                    waitingSeconds: Self.seconds(now - $0.requestedAt),
                    priority: $0.isPriority,
                    preempted: $0.preemptedAt != nil
                )
            }
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
        state.reconcile(
            now: uptime(),
            buildActive: buildActive,
            grace: config.staleGrantGrace,
            yieldDeadline: config.yieldDeadline
        )
    }

    /// Elapsed time since the server started.
    private func uptime() -> Duration {
        startInstant.duration(to: clock.now)
    }

    /// Whole seconds in a duration, for the snapshot's age fields.
    private static func seconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds)
    }
}
