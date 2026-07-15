import Foundation
import MCP

/// Declares the MCP tools the control tower exposes and routes `tools/call`
/// requests to the `BuildQueue`.
enum ToolCatalog {
    /// The tools advertised to clients via `tools/list`.
    static let all: [Tool] = [
        Tool(
            name: "request_build",
            description: """
                Request permission to build. Call this only when you are ready to \
                build right now — as the immediate step before you start the build, \
                not while you still have edits or other work to do first. Adds you \
                to the global build queue and returns a ticket id plus whether you \
                are cleared to build now. If you are not cleared, poll build_status \
                with the returned ticket until it reports GRANTED, then run your \
                build. Call finish_build the moment the build finishes — or right \
                away if anything stops it from running — so you never hold the \
                ticket during unrelated work.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "agent": [
                        "type": "string",
                        "description": "Optional label identifying the requester, shown in queue_status.",
                    ]
                ],
            ]
        ),
        Tool(
            name: "build_status",
            description: """
                Check whether your ticket has been cleared to build. Call this \
                periodically (about every 30-60 seconds) while waiting.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "ticket": [
                        "type": "string",
                        "description": "The ticket id returned by request_build.",
                    ]
                ],
                "required": ["ticket"],
            ]
        ),
        Tool(
            name: "finish_build",
            description: """
                Release your build slot so the next agent can build. Call this the \
                moment your build finishes (success or failure), and immediately if \
                the build is cancelled, blocked, or you get sidetracked before it \
                runs — never hold the ticket while doing unrelated work. Also call \
                it to abandon a queued request.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "ticket": [
                        "type": "string",
                        "description": "The ticket id returned by request_build.",
                    ]
                ],
                "required": ["ticket"],
            ]
        ),
        Tool(
            name: "queue_status",
            description: "Show the current build queue: who holds the active slot and who is waiting.",
            inputSchema: [
                "type": "object",
                "properties": [:],
            ]
        ),
    ]

    /// Dispatch a `tools/call` to the queue and format the reply.
    static func handle(_ params: CallTool.Parameters, queue: BuildQueue) async -> CallTool.Result {
        switch params.name {
        case "request_build":
            let agent = params.arguments?["agent"]?.stringValue
            let (id, disposition) = await queue.request(agent: agent)
            return text(message(ticket: id, disposition: disposition))

        case "build_status":
            guard let id = ticketID(params) else { return missingTicket() }
            let disposition = await queue.status(of: id)
            return text(message(ticket: id, disposition: disposition), isError: disposition == .unknown)

        case "finish_build":
            guard let id = ticketID(params) else { return missingTicket() }
            let held = await queue.finish(id)
            let reply =
                held
                ? "Released ticket \(id.uuidString). The next agent may now build."
                : "Ticket \(id.uuidString) was not active or queued (already finished?)."
            return text(reply)

        case "queue_status":
            let snapshot = await queue.snapshot()
            return text(snapshot.description)

        default:
            return text("Unknown tool '\(params.name)'.", isError: true)
        }
    }

    // MARK: - Helpers

    private static func ticketID(_ params: CallTool.Parameters) -> UUID? {
        guard let raw = params.arguments?["ticket"]?.stringValue else { return nil }
        return UUID(uuidString: raw)
    }

    private static func message(ticket: UUID, disposition: BuildDisposition) -> String {
        switch disposition {
        case .granted:
            return """
                GRANTED. You may build now (ticket \(ticket.uuidString)). Run your \
                build, then call finish_build with this ticket.
                """
        case .queued(let position):
            return """
                QUEUED at position \(position) (ticket \(ticket.uuidString)). Wait, \
                then poll build_status with this ticket until it reports GRANTED.
                """
        case .unknown:
            return """
                Ticket \(ticket.uuidString) is not in the queue. It may have already \
                finished or been reclaimed after going silent; call request_build again.
                """
        }
    }

    private static func missingTicket() -> CallTool.Result {
        text("Missing or invalid 'ticket' argument (expected a ticket id from request_build).", isError: true)
    }

    private static func text(_ message: String, isError: Bool = false) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: isError
        )
    }
}
