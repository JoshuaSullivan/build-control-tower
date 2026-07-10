import Foundation

/// One entry in a `QueueSnapshot`.
struct ActiveEntry: Sendable {
    let id: UUID
    let agent: String?
    var label: String { "\(agent ?? "unnamed") [\(id.uuidString)]" }
}

/// One waiting entry in a `QueueSnapshot`.
struct WaitingEntry: Sendable {
    let id: UUID
    let agent: String?
    var label: String { "\(agent ?? "unnamed") [\(id.uuidString)]" }
}

/// A point-in-time view of the queue, rendered for the `queue_status` tool.
struct QueueSnapshot: Sendable, CustomStringConvertible {
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
