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
                build. \

                Holding the slot obliges you to call build_heartbeat with your \
                ticket at least once per interval — the GRANTED reply quotes the \
                interval in seconds — for the entire time the build runs. A ticket \
                that stops checking in is treated as a crashed agent and its slot \
                is given away mid-build. So plan the build around that before you \
                request: run it in the background against a log file, or with a \
                wait shorter than the quoted interval, so you actually get turns in \
                which to check in. Do not fetch full build logs for progress; \
                heartbeat without progress if unknown. Immediately delete each \
                GetBuildLog temporary file after checking it, before the next \
                poll. Keep a live build's output log until its writer exits, then \
                extract needed diagnostics and delete it. Call finish_build the \
                moment the build finishes — or right away if anything stops it \
                from running — so you never hold the ticket during unrelated work.

                When delegation is available, use one low-cost monitoring agent \
                (e.g. Luna at medium reasoning effort), not an expensive model \
                for repeated polling. Hand off this ticket and heartbeat cadence \
                explicitly; do not request a second ticket for the monitor.
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
            name: "request_priority_build",
            description: """
                Jump the build queue, interrupting whatever is building now. USE \
                THIS ONLY when your human has explicitly told you this build must \
                run immediately — not because your own work feels urgent, blocking, \
                or important. Every agent's build feels urgent to that agent; if \
                everyone takes priority, the queue is meaningless and everyone \
                waits longer. If you are choosing this on your own initiative, \
                you want request_build instead. \

                What happens: the agent currently building is told to abort its \
                build and drops to the head of the queue, and you take the slot. \
                That is destructive — you are throwing away someone else's \
                partially-finished build — so the bar is a human asking for it. \

                Because the tower cannot interrupt a running agent, a build that is \
                actively burning CPU is given a short window to stop cleanly, and \
                the slot is taken by force if it doesn't. So you may come back \
                QUEUED rather than GRANTED. If so, poll build_status every 5-10 \
                seconds — much faster than a normal wait — so you claim the slot \
                the instant it is released. Once GRANTED you have exactly the same \
                obligations as any other build: heartbeat at the quoted interval, \
                and finish_build the moment you are done. Do not fetch full logs \
                just for progress; immediately delete each fetched temporary log \
                after checking it, before the next poll.
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
                            Short description of what you are building. Shown in \
                            queue_status, where it is the only clue a human has \
                            about why a running build was interrupted, so make it \
                            specific. Please provide it.
                            """,
                    ],
                ],
            ]
        ),
        Tool(
            name: "build_status",
            description: """
                Check whether your ticket has been cleared to build. Call this \
                periodically (about every 30-60 seconds) while waiting. Once it \
                reports GRANTED and your build is running, switch to \
                build_heartbeat — that is the call you owe the tower while you \
                hold the slot. Prefer a low-cost monitor (e.g. Luna at medium \
                reasoning effort, when available) over expensive model turns \
                spent only polling. A delegated queue monitor must notify the \
                parent when GRANTED so the parent can start the build.
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
                Report that your build is still running. This is required, not \
                optional: you must call it at least once per interval for as long \
                as you hold the slot, on every build, not just the ones you expect \
                to be slow. \

                Use the interval this server quoted you: the GRANTED reply names \
                the number of seconds to wait between check-ins, and each \
                heartbeat reply repeats it. Do not assume a fixed cadence — the \
                daemon derives it from its own stale-grant window, which the \
                operator can retune, so the number you were given is the only \
                correct one. Beating more often than asked is harmless; beating \
                less often loses you the slot. \

                A grant that goes silent past the stale window is assumed to \
                belong to a crashed agent and is reclaimed, and the next agent is \
                cleared to build — while your build is still running. Nothing \
                about a quiet build (dependency resolution, linking, indexing, a \
                test phase, an Xcode-driven build) distinguishes it from a dead \
                one except your check-ins. \

                If you have no turn in which to call this, you started the build \
                wrong: don't run it as a single blocking foreground call. Launch it \
                in the background writing to a log file, or with a wait/timeout \
                shorter than the quoted interval, then loop — check status, \
                heartbeat, wait — until it exits. Checking in is also the only way \
                you find out that a priority build has been granted your slot, or \
                needs you to stand down. Include 'progress' whenever you \
                can estimate it cheaply (targets compiled so far, a bounded tail \
                of the existing log, elapsed time versus usual build duration) \
                — a rough guess is far more useful to everyone watching than \
                nothing. Omit progress when unknown: a heartbeat does not require \
                GetBuildLog. Do not fetch/copy full logs just to poll progress. \
                If you fetch a log, immediately delete that call's generated \
                temporary file and any copies after extracting what you need, \
                BEFORE the next poll, even on failure or cancellation. Delete \
                only exact temporary paths, never Xcode's original logs or result \
                bundles. Do not delete/truncate a live output log; read it \
                incrementally and remove it only after its writer exits.

                This is routine monitoring, not expensive reasoning work. When \
                supported, delegate it to one low-cost agent such as Luna at \
                medium reasoning effort, reusing that agent across polls. Give \
                it the existing ticket, interval, build handle, and log paths; \
                assign one owner for heartbeats, finish_build, and cleanup. \
                Report GRANTED, completion, actionable failures, and yield/stop \
                requests to the parent rather than waking an expensive model \
                every poll. If delegation is unavailable, keep checking in on \
                time yourself.
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
                            Optional; include it when cheaply available, otherwise \
                            omit it rather than fetching a full build log. Shown \
                            to other agents and in the monitoring UI.
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
                it to abandon a queued request. After the build's log writer \
                exits, extract needed diagnostics and delete your temporary \
                output log. Fetched log snapshots must already have been deleted \
                immediately after each check.
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
        let yieldSeconds = await Int(queue.yieldDeadline.components.seconds)
        let timing = Timing(heartbeatSeconds: heartbeatSeconds, yieldSeconds: yieldSeconds)

        switch params.name {
        case "request_build", "request_priority_build":
            let agent = params.arguments?["agent"]?.stringValue
            let task = params.arguments?["task"]?.stringValue
            let isPriority = params.name == "request_priority_build"
            let (id, disposition) = await queue.request(agent: agent, task: task, priority: isPriority)
            return text(message(ticket: id, disposition: disposition, timing: timing, isPriority: isPriority))

        case "build_status":
            guard let id = ticketID(params) else { return missingTicket() }
            let disposition = await queue.status(of: id)
            return text(
                message(ticket: id, disposition: disposition, timing: timing),
                isError: disposition == .unknown
            )

        case "build_heartbeat":
            guard let id = ticketID(params) else { return missingTicket() }
            let (disposition, progress) = await queue.heartbeat(id, progress: progressValue(params))
            guard disposition == .granted else {
                // The ticket lost the slot, was asked to give it up, or never held
                // it; tell the agent where it actually stands rather than silently
                // accepting the beat.
                return text(
                    message(ticket: id, disposition: disposition, timing: timing),
                    isError: disposition == .unknown
                )
            }
            // Echo the estimate the tower now holds — which is the last one
            // reported if this beat carried no number.
            let reported = progress.map { " (recorded progress: \($0)%)" } ?? ""
            return text(
                """
                Heartbeat recorded for ticket \(id.uuidString)\(reported). Your \
                slot is covered for another \(heartbeatSeconds)s — keep building, \
                and call build_heartbeat again within \(heartbeatSeconds)s or the \
                slot can be reclaimed while your build is still running. Call \
                finish_build the moment the build is done. Do not fetch a full \
                log for progress; immediately delete any fetched temporary log \
                after checking it, before the next poll.
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

    /// The timing policy quoted to agents in replies. Bundled so every message
    /// helper takes one parameter instead of a growing list of loose seconds.
    private struct Timing {
        /// How often a holder must call `build_heartbeat`.
        let heartbeatSeconds: Int
        /// How long a pre-empted holder has to release the slot voluntarily.
        let yieldSeconds: Int
    }

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
        timing: Timing,
        isPriority: Bool = false
    ) -> String {
        let heartbeatSeconds = timing.heartbeatSeconds

        switch disposition {
        case .granted:
            return """
                GRANTED — the build slot is yours (ticket \(ticket.uuidString)).

                REQUIRED while you hold it: call build_heartbeat with this ticket \
                at least once every \(heartbeatSeconds)s, with a 0-100 progress \
                estimate when you can make one, until the build ends. Start the \
                build so that you can — in the background writing to a log, or \
                with a wait shorter than \(heartbeatSeconds)s — rather than as one \
                blocking call you cannot interrupt. Checking in is also how you \
                find out if a priority build needs you to stand down. A ticket \
                that goes quiet is treated as a crashed agent: the slot is \
                reclaimed and handed to the next agent, who will then be building \
                at the same time as you.

                Prefer one low-cost monitoring agent (e.g. Luna at medium \
                reasoning effort, when available), not expensive model turns \
                for polling. Hand off this ticket and interval explicitly, with \
                one owner for heartbeats, finish_build, and cleanup; do not \
                request a second ticket or skip check-ins during the handoff.

                Do not fetch full logs just to report progress; use status, \
                elapsed time, or a bounded read of your existing log instead. \
                If you call GetBuildLog, immediately delete that call's generated \
                temporary file and any copies after checking it, before the next \
                poll. Delete only those exact temporary paths, not Xcode's \
                original logs or result bundles. Keep a live output log until \
                its writer exits, then extract needed diagnostics and delete it.

                Call finish_build the moment the build ends, success or failure.
                """

        case .yieldRequested:
            return """
                STOP BUILDING NOW — a priority build has been requested and needs \
                this slot (ticket \(ticket.uuidString)).

                Kill your build immediately, then call finish_build with this \
                ticket to hand the slot over cleanly. Do not start another build. \
                You keep your place: a new ticket goes to the head of the queue, \
                so request_build again once you've released this one and you will \
                be next up.

                If you do not release it within \(timing.yieldSeconds)s of the \
                request, the slot is taken anyway — and your build would then be \
                running alongside the priority one, which is exactly what this \
                tower exists to prevent.
                """

        case .queued(let position):
            let tail =
                isPriority
                ? """
                    A build is already running and cannot be interrupted \
                    instantly, so it has been asked to stand down (it has up to \
                    \(timing.yieldSeconds)s before the slot is taken from it). \
                    Poll build_status with this ticket every 5-10 SECONDS — much \
                    faster than a normal wait — so you take the slot the instant \
                    it frees up.
                    """
                : """
                    Wait, then poll build_status with this ticket until it reports \
                    GRANTED. Once granted you will owe a build_heartbeat every \
                    \(heartbeatSeconds)s until the build ends, so plan to run the \
                    build in a way that leaves you turns to check in.
                    """
            return """
                QUEUED at position \(position) (ticket \(ticket.uuidString)). \(tail)
                """

        case .preempted(let position):
            return """
                PRE-EMPTED — your build slot was taken by a priority build (ticket \
                \(ticket.uuidString)).

                Kill your build now if it is still running; it is no longer \
                authorized and would be competing with the priority build for the \
                machine. Your ticket is still valid and sits at position \
                \(position) in the queue, so you do not need to request again — \
                poll build_status with it until it reports GRANTED, then start the \
                build over.
                """

        case .unknown:
            return """
                Ticket \(ticket.uuidString) is not in the queue — it either already \
                finished, or it was reclaimed after going silent past the \
                \(heartbeatSeconds)s check-in window. If your build is still \
                running, another agent may already have been cleared to build \
                alongside it. Call request_build again, and this time call \
                build_heartbeat every \(heartbeatSeconds)s so the slot isn't taken \
                from you while you are using it.
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
