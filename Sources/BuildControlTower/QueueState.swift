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
}

/// What a caller learns about a ticket when it requests or polls.
enum BuildDisposition: Sendable, Equatable {
    /// Cleared to build now.
    case granted
    /// Still waiting; `position` is 1-based among waiting requests.
    case queued(position: Int)
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

    /// Append a new request to the back of the queue.
    mutating func enqueue(_ ticket: BuildTicket) {
        waiting.append(ticket)
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
            return .granted
        }
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            return .queued(position: index + 1)
        }
        return .unknown
    }

    /// The core transition — see `tech-spec.md` › "Queue advancement".
    ///
    /// - When a grant is outstanding, this call never grants a second one. It
    ///   either keeps waiting or, only if the grantee has been silent past
    ///   `grace` with no build CPU observed, reclaims it (crashed / silent
    ///   agent) and then advances. Silence is measured from `lastSeen`, so a
    ///   heartbeat or status poll extends the grant; heartbeats can only ever
    ///   prolong a grant, never cut one short.
    /// - When no grant is outstanding, it advances to the head of the queue —
    ///   but withholds the grant while `buildActive` is true, since that CPU
    ///   belongs to a build we didn't authorize (e.g. a manual build in Xcode).
    ///
    /// - Parameters:
    ///   - now: current server uptime.
    ///   - buildActive: whether the probe currently sees a build burning CPU.
    ///   - grace: the stale-grant window from `Configuration`.
    /// - Returns: the ticket newly granted by this call, if any.
    @discardableResult
    mutating func reconcile(now: Duration, buildActive: Bool, grace: Duration) -> BuildTicket? {
        if let current = active {
            let silentFor = now - current.lastSeen
            // While a grant is outstanding, observed build CPU is presumed to
            // be the grantee's own build, so we keep waiting. We only reclaim
            // when the grant has gone quiet past the grace window.
            guard silentFor > grace, !buildActive else {
                return nil
            }
            active = nil
        }

        // No grant outstanding. Advance unless something is already building.
        guard active == nil, !waiting.isEmpty, !buildActive else {
            return nil
        }
        let next = waiting.removeFirst()
        active = ActiveGrant(ticket: next, grantedAt: now, lastSeen: now, progress: nil)
        return next
    }
}
