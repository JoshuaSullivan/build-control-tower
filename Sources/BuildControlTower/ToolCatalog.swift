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
                build. While the build runs, send build_heartbeat periodically so \
                the tower knows you are still alive. Call finish_build the moment \
                the build finishes — or right away if anything stops it from \
                running — so you never hold the ticket during unrelated work.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "agent": [
                        "type": "string",
                        "description": """
                            Short label identifying you, shown in queue_status \
                            (e.g. 'claude-A'). Please provide it.
                            """,
                    ],
                    "task": [
                        "type": "string",
                        "description": """
                            Short description of what you are building, e.g. \
                            'xcodebuild Teams iOS scheme' or 'swift test after \
                            auth refactor'. Shown in queue_status so a human \
                            watching several queued agents can tell them apart. \
                            Please provide it.
                            """,
                    ],
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
            name: "build_heartbeat",
            description: """
                Report that your build is still running. Call this for as long as \
                the build is in progress — between checking the build output, \
                tailing the log, or waiting on a long compile. \

                Use the interval this server quoted you: the GRANTED reply names \
                the number of seconds to wait between check-ins, and each \
                heartbeat reply repeats it. Do not assume a fixed cadence — the \
                daemon derives it from its own stale-grant window, which the \
                operator can retune, so the number you were given is the only \
                correct one. Beating more often than asked is harmless; beating \
                less often risks your slot. \
                A grant that goes silent past the stale window with no build CPU \
                visible is assumed to belong to a crashed agent and is reclaimed, \
                so heartbeats are what keep a long or quiet build from losing its \
                slot. Include 'progress' whenever you can estimate it at all \
                (targets compiled so far, position in the build log, elapsed time \
                versus how long this build usually takes) — a rough guess is far \
                more useful to everyone watching than nothing.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "ticket": [
                        "type": "string",
                        "description": "The ticket id returned by request_build.",
                    ],
                    "progress": [
                        "type": "number",
                        "description": """
                            Your best guess at how far along the build is, 0-100. \
                            Optional but strongly encouraged; it is shown to other \
                            agents and in the monitoring UI. An estimate is fine.
                            """,
                        "minimum": 0,
                        "maximum": 100,
                    ],
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
        let heartbeatSeconds = await Int(queue.recommendedHeartbeatInterval.components.seconds)

        switch params.name {
        case "request_build":
            let agent = params.arguments?["agent"]?.stringValue
            let task = params.arguments?["task"]?.stringValue
            let (id, disposition) = await queue.request(agent: agent, task: task)
            return text(message(ticket: id, disposition: disposition, heartbeatSeconds: heartbeatSeconds))

        case "build_status":
            guard let id = ticketID(params) else { return missingTicket() }
            let disposition = await queue.status(of: id)
            return text(
                message(ticket: id, disposition: disposition, heartbeatSeconds: heartbeatSeconds),
                isError: disposition == .unknown
            )

        case "build_heartbeat":
            guard let id = ticketID(params) else { return missingTicket() }
            let (disposition, progress) = await queue.heartbeat(id, progress: progressValue(params))
            guard disposition == .granted else {
                // The ticket lost (or never held) the slot; tell the agent where
                // it actually stands rather than silently accepting the beat.
                return text(
                    message(ticket: id, disposition: disposition, heartbeatSeconds: heartbeatSeconds),
                    isError: disposition == .unknown
                )
            }
            // Echo the estimate the tower now holds — which is the last one
            // reported if this beat carried no number.
            let reported = progress.map { " (recorded progress: \($0)%)" } ?? ""
            return text(
                """
                Heartbeat recorded for ticket \(id.uuidString)\(reported). Keep \
                building, check in again in about \(heartbeatSeconds)s, and call \
                finish_build the moment the build is done.
                """
            )

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

    /// Best-effort read of the optional progress argument.
    ///
    /// The schema asks for a number, but a stringified one ("45") is common
    /// enough from model-driven clients that dropping the estimate on the floor
    /// would be the worse outcome. `QueueState.touch` does the clamping.
    private static func progressValue(_ params: CallTool.Parameters) -> Int? {
        guard let raw = params.arguments?["progress"] else { return nil }
        if let value = raw.intValue { return value }
        if let value = raw.doubleValue { return Int(value.rounded()) }
        if let text = raw.stringValue, let value = Double(text) { return Int(value.rounded()) }
        return nil
    }

    private static func message(
        ticket: UUID,
        disposition: BuildDisposition,
        heartbeatSeconds: Int
    ) -> String {
        switch disposition {
        case .granted:
            return """
                GRANTED. You may build now (ticket \(ticket.uuidString)). Run your \
                build, call build_heartbeat with this ticket about every \
                \(heartbeatSeconds)s while it runs — with a progress estimate if \
                you can make one — then call finish_build as soon as it ends.
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
