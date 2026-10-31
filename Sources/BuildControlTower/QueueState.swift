import Foundation

/// A single request for a build slot.
struct BuildTicket: Sendable, Equatable, Identifiable {
    let id: UUID
    let agent: String?
    /// Short description of what is being built, shown alongside `agent` so a
    /// human watching the queue can tell concurrent agents apart.
    let task: String?
    /// Server uptime at which the request was enqueued.
    let requestedAt: Duration

    /// Whether this request was made on a human's explicit instruction to jump
    /// the queue. A priority ticket outranks normal ones in the waiting line,
    /// pre-empts a running normal build, and is granted even when an external
    /// build is burning CPU.
    var isPriority: Bool = false

    /// Uptime at which this ticket was knocked out of the active slot by a
    /// priority request, if it was.
    ///
    /// Two jobs: it ranks the ticket ahead of everything else in the waiting
    /// line (an interrupted build resumes first, wasting the least work), and it
    /// is the flag that makes the owner's next check-in report `.preempted`
    /// instead of a bland `.queued`, so it learns it must stop building.
    var preemptedAt: Duration? = nil

    /// Where this ticket sits in the waiting-line ordering. Lower sorts first.
    ///
    /// Pre-empted tickets outrank fresh priority requests deliberately: their
    /// build was already underway and interrupted, so resuming them first
    /// discards the least work.
    var rank: Int {
        if preemptedAt != nil { return 0 }
        return isPriority ? 1 : 2
    }
}

/// The ticket holding the build slot, plus the liveness and progress its owner
/// has reported since the grant.
struct ActiveGrant: Sendable {
    let ticket: BuildTicket

    /// Uptime the slot was granted — used for elapsed-time display.
    let grantedAt: Duration

    /// Uptime of the most recent sign of life (the grant itself, a heartbeat, or
    /// a status poll). This, not `grantedAt`, is what the stale-grant reclaim
    /// measures, so an agent that keeps checking in is never presumed dead.
    var lastSeen: Duration

    /// The grantee's own estimate of build completion, `0...100`, if reported.
    var progress: Int?

    /// Uptime at which a priority request asked this grant to stand down, if one
    /// has. The daemon cannot interrupt the agent, so this flag simply waits
    /// here until the agent's next check-in reports `.yieldRequested` to it.
    ///
    /// Cleared again if the priority ticket disappears before the holder
    /// complies, so a cancelled pre-emption doesn't kill a healthy build.
    var yieldRequestedAt: Duration?
}

/// What a caller learns about a ticket when it requests or polls.
enum BuildDisposition: Sendable, Equatable {
    /// Cleared to build now.
    case granted
    /// Still holds the slot, but a priority build is waiting on it: stop the
    /// build and call `finish_build` now. Distinct from `.preempted` — the slot
    /// has not been taken away yet, so complying keeps the handoff clean.
    case yieldRequested
    /// Still waiting; `position` is 1-based among waiting requests.
    case queued(position: Int)
    /// The slot was taken by a priority build. Stop building; `position` is where
    /// the ticket now sits in the waiting line (1 = next up).
    case preempted(position: Int)
    /// No such ticket (never existed, already finished, or was reclaimed).
    case unknown
}

/// The pure, deterministic core of the control tower.
///
/// All time is expressed as a `Duration` measured from server start ("uptime"),
/// and the "is a build running?" signal is passed in as a `Bool`, so this type
/// has no dependency on a clock or on the system probe and can be unit-tested
/// exhaustively. `BuildQueue` supplies the real time and probe readings.
///
/// The single invariant this type guarantees: **at most one ticket is `active`
/// at any moment.**
struct QueueState: Sendable {
    /// Requests waiting for a slot, in FIFO order.
    private(set) var waiting: [BuildTicket] = []

    /// The ticket currently holding the build slot, with the liveness and
    /// progress its owner has reported.
    private(set) var active: ActiveGrant?

    /// Insert a request into the waiting line at its rank.
    ///
    /// Normal requests still land at the back, so the common case is unchanged
    /// FIFO. A priority request jumps ahead of normal ones, and a pre-empted
    /// ticket ahead of those, always joining the *back* of its own rank group so
    /// tickets of equal standing keep arrival order.
    mutating func enqueue(_ ticket: BuildTicket) {
        let index = waiting.firstIndex { $0.rank > ticket.rank } ?? waiting.endIndex
        waiting.insert(ticket, at: index)
    }

    /// Remove the ticket from wherever it sits — the active slot or the waiting
    /// line. Returns `true` if it actually held a place.
    @discardableResult
    mutating func release(_ id: UUID) -> Bool {
        if let active, active.ticket.id == id {
            self.active = nil
            return true
        }
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index)
            return true
        }
        return false
    }

    /// Raise a waiting ticket to priority and re-file it at its new rank.
    ///
    /// This is what the monitor's `POST /promote` drives. It only marks the
    /// ticket; the pre-emption itself happens on the next `reconcile`, which is
    /// where the build-CPU reading lives.
    ///
    /// - Returns: `true` if a waiting ticket was promoted. An unknown ticket, or
    ///   one that already holds the slot (nothing to promote it past), is `false`.
    @discardableResult
    mutating func promote(_ id: UUID) -> Bool {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return false }
        var ticket = waiting.remove(at: index)
        ticket.isPriority = true
        enqueue(ticket)
        return true
    }

    /// Clear the pre-emption marker once its owner has been told, so the ticket
    /// reports as ordinarily queued from then on rather than repeating the
    /// alarm for the rest of its wait.
    ///
    /// Deliberately does *not* re-file the ticket: it keeps the head-of-line
    /// place its interrupted build earned. New arrivals still sort behind it,
    /// since `enqueue` walks to the first strictly-higher rank.
    mutating func acknowledgePreemption(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting[index].preemptedAt = nil
    }

    /// Record that the grantee is still alive, optionally with its own estimate
    /// of how far along the build is.
    ///
    /// Only the ticket holding the active slot can be touched — a waiting ticket
    /// has nothing to keep alive, since only grants are ever reclaimed.
    ///
    /// - Parameters:
    ///   - id: the ticket checking in.
    ///   - now: current server uptime.
    ///   - progress: completion estimate; clamped to `0...100`. Passing `nil`
    ///     leaves any previous estimate intact, so a heartbeat without a number
    ///     doesn't erase the last one.
    /// - Returns: `true` if `id` holds the active slot.
    @discardableResult
    mutating func touch(_ id: UUID, now: Duration, progress: Int? = nil) -> Bool {
        guard var current = active, current.ticket.id == id else { return false }

        current.lastSeen = now
        if let progress {
            current.progress = min(max(progress, 0), 100)
        }
        active = current
        return true
    }

    /// Where a ticket currently stands.
    func disposition(of id: UUID) -> BuildDisposition {
        if let active, active.ticket.id == id {
            return active.yieldRequestedAt == nil ? .granted : .yieldRequested
        }
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            return waiting[index].preemptedAt == nil
                ? .queued(position: index + 1)
                : .preempted(position: index + 1)
        }
        return .unknown
    }

    /// Whether a priority request is waiting that the active grant should stand
    /// down for.
    ///
    /// A priority grant is not itself pre-emptible: a second priority request
    /// waits its turn rather than starting a chain of interruptions that throws
    /// away more work at every link.
    private var priorityAwaitsPreemption: Bool {
        guard let active, !active.ticket.isPriority else { return false }
        return waiting.contains { $0.isPriority }
    }

    /// The core transition — see `tech-spec.md` › "Queue advancement".
    ///
    /// - When a grant is outstanding, this call never grants a second one. It
    ///   either keeps waiting or gives up the grant for one of two reasons:
    ///   *stale* (the grantee has been silent past `grace` with no build CPU, so
    ///   it is presumed crashed), or *pre-empted* (a priority request is waiting).
    ///   Silence is measured from `lastSeen`, so a heartbeat or status poll
    ///   extends the grant; heartbeats can only ever prolong a grant, never cut
    ///   one short.
    /// - Pre-emption is adaptive, because the daemon cannot interrupt an agent
    ///   mid-build: with no build CPU visible the holder isn't really building,
    ///   so the slot moves immediately; with a build clearly running the grant is
    ///   only *marked* `yieldRequestedAt`, giving the agent until `yieldDeadline`
    ///   to notice on its next check-in and stop cleanly before the slot is taken
    ///   anyway.
    /// - When no grant is outstanding, it advances to the head of the queue —
    ///   but withholds the grant while `buildActive` is true, since that CPU
    ///   belongs to a build we didn't authorize (e.g. a manual build in Xcode).
    ///   A priority request overrides that guard: the human asked for this build
    ///   now, and an external build owns no ticket that could yield to it.
    ///
    /// - Parameters:
    ///   - now: current server uptime.
    ///   - buildActive: whether the probe currently sees a build burning CPU.
    ///   - grace: the stale-grant window from `Configuration`.
    ///   - yieldDeadline: how long a pre-empted grant has to stand down on its
    ///     own before the slot is taken from it. Defaults to zero — i.e. seize
    ///     at once — purely so the many tests that never involve a priority
    ///     ticket can omit it; it has no effect unless one is waiting. The only
    ///     production caller, `BuildQueue`, always passes the configured window.
    /// - Returns: the ticket newly granted by this call, if any.
    @discardableResult
    mutating func reconcile(
        now: Duration,
        buildActive: Bool,
        grace: Duration,
        yieldDeadline: Duration = .seconds(0)
    ) -> BuildTicket? {
        var displaced: BuildTicket?

        if var current = active {
            // A pre-emption that lost its cause — the priority ticket finished or
            // was abandoned while we waited — must not go on to kill a healthy
            // build, so stand the holder back down.
            if current.yieldRequestedAt != nil, !priorityAwaitsPreemption {
                current.yieldRequestedAt = nil
                active = current
            }

            let silentFor = now - current.lastSeen
            // While a grant is outstanding, observed build CPU is presumed to
            // be the grantee's own build, so we keep waiting. We only reclaim
            // when the grant has gone quiet past the grace window.
            let isStale = silentFor > grace && !buildActive

            if !isStale {
                guard priorityAwaitsPreemption else { return nil }

                if buildActive {
                    // A real build is running. Ask it to stop and let the agent
                    // hear about it on its next check-in; only take the slot by
                    // force once that chance has demonstrably passed.
                    let requestedAt = current.yieldRequestedAt ?? now
                    current.yieldRequestedAt = requestedAt
                    active = current
                    guard now - requestedAt >= yieldDeadline else { return nil }
                }
                // Either nothing is building (so there is nothing to interrupt)
                // or the holder ignored the request past its deadline. Hold the
                // ticket back until after the advance below: re-filing it now
                // would put it at the head of the line and hand the slot
                // straight back to the build we are pre-empting.
                var ticket = current.ticket
                ticket.preemptedAt = now
                displaced = ticket
            }

            active = nil
        }

        // No grant outstanding. Advance unless something is already building —
        // which a priority request is entitled to ignore.
        var granted: BuildTicket?
        if let next = waiting.first, !buildActive || next.isPriority {
            waiting.removeFirst()
            active = ActiveGrant(ticket: next, grantedAt: now, lastSeen: now, progress: nil)
            granted = next
        }

        // Now that the pre-empting build holds the slot, the interrupted one
        // takes the place directly behind it and resumes first.
        if let displaced {
            enqueue(displaced)
        }
        return granted
    }
}
