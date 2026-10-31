import Foundation

/// The active entry in a `QueueSnapshot`.
///
/// `Encodable` so the `/status` HTTP endpoint can serialize it as JSON; only the
/// stored properties are emitted, not the computed `label`. Ages are plain
/// second counts rather than `Duration`s, whose synthesized encoding is an
/// opaque components pair that consumers would have to special-case.
struct ActiveEntry: Sendable, Encodable {
    let id: UUID
    let agent: String?
    let task: String?
    /// The grantee's own completion estimate, `0...100`, if it has reported one.
    let progress: Int?
    /// Seconds since the slot was granted.
    let elapsedSeconds: Int
    /// Seconds since the grantee last checked in (heartbeat or status poll).
    let secondsSinceHeartbeat: Int

    /// Whether this build jumped the queue on a human's explicit instruction.
    let priority: Bool

    /// Seconds since a priority request asked this build to stand down, or `nil`
    /// if it hasn't been asked. Non-nil means the build is living on borrowed
    /// time: it keeps the slot only until its agent complies or the yield
    /// deadline passes.
    let yieldRequestedSecondsAgo: Int?

    var label: String {
        var text = agent ?? "unnamed"
        if let task { text += " — \(task)" }
        text += " [\(id.uuidString)]"
        if priority { text += " · PRIORITY" }
        if let progress { text += " · \(progress)%" }
        text += " · \(Self.age(elapsedSeconds)) elapsed"
        text += " · updated \(Self.age(secondsSinceHeartbeat)) ago"
        if let yieldRequestedSecondsAgo {
            text += " · YIELD REQUESTED \(Self.age(yieldRequestedSecondsAgo)) ago"
        }
        return text
    }

    /// Compact age rendering: seconds under a minute, otherwise whole minutes.
    static func age(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
    }
}

/// One waiting entry in a `QueueSnapshot`.
struct WaitingEntry: Sendable, Encodable {
    let id: UUID
    let agent: String?
    let task: String?
    /// Seconds this request has been in the queue.
    let waitingSeconds: Int

    /// Whether this request jumped the queue on a human's explicit instruction.
    let priority: Bool

    /// Whether this ticket was knocked out of the active slot by a priority
    /// build and is waiting to resume.
    let preempted: Bool

    var label: String {
        var text = agent ?? "unnamed"
        if let task { text += " — \(task)" }
        text += " [\(id.uuidString)]"
        if priority { text += " · PRIORITY" }
        if preempted { text += " · PRE-EMPTED" }
        text += " · waiting \(ActiveEntry.age(waitingSeconds))"
        return text
    }
}

/// A point-in-time view of the queue, rendered for the `queue_status` tool and
/// serialized as JSON by the `/status` endpoint.
struct QueueSnapshot: Sendable, Encodable, CustomStringConvertible {
    let active: ActiveEntry?
    let waiting: [WaitingEntry]

    var description: String {
        var lines: [String] = []
        lines.append("Active build: \(active?.label ?? "none")")

        if waiting.isEmpty {
            lines.append("Waiting: none")
        } else {
            lines.append("Waiting (\(waiting.count)):")
            for (index, entry) in waiting.enumerated() {
                lines.append("  \(index + 1). \(entry.label)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
