import Foundation

/// A single request for a build slot.
struct BuildTicket: Sendable, Equatable, Identifiable {
    let id: UUID
    let agent: String?
    /// Server uptime at which the request was enqueued.
    let requestedAt: Duration
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

    /// The ticket currently holding the build slot, and the uptime it was
    /// granted (used to detect a stale grant).
    private(set) var active: (ticket: BuildTicket, grantedAt: Duration)?

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
    ///   either keeps waiting or, only if the grant has been idle past `grace`
    ///   with no build CPU observed, reclaims it (crashed / silent agent) and
    ///   then advances.
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
            let idleFor = now - current.grantedAt
            // While a grant is outstanding, observed build CPU is presumed to
            // be the grantee's own build, so we keep waiting. We only reclaim
            // when the grant has gone quiet past the grace window.
            guard idleFor > grace, !buildActive else {
                return nil
            }
            active = nil
        }

        // No grant outstanding. Advance unless something is already building.
        guard active == nil, !waiting.isEmpty, !buildActive else {
            return nil
        }
        let next = waiting.removeFirst()
        active = (ticket: next, grantedAt: now)
        return next
    }
}
