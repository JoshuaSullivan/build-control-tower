import Foundation

/// One entry in a `QueueSnapshot`.
///
/// `Encodable` so the `/status` HTTP endpoint can serialize it as JSON; only
/// the stored `id`/`agent` are emitted, not the computed `label`.
struct ActiveEntry: Sendable, Encodable {
    let id: UUID
    let agent: String?
    var label: String { "\(agent ?? "unnamed") [\(id.uuidString)]" }
}

/// One waiting entry in a `QueueSnapshot`.
struct WaitingEntry: Sendable, Encodable {
    let id: UUID
    let agent: String?
    var label: String { "\(agent ?? "unnamed") [\(id.uuidString)]" }
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
