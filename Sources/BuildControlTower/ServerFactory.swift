import Foundation
import MCP

/// Builds the MCP `Server` and wires its method handlers to the `BuildQueue`.
enum ServerFactory {
    /// The server version, reported both in the MCP `initialize` response and by
    /// the `/config` endpoint. Defined once so the two can never disagree about
    /// which daemon a client is talking to.
    static let version = "0.3.0"

    /// Server-level guidance sent to clients in the `initialize` response. Unlike
    /// the per-tool descriptions (seen only once an agent inspects a tool), this
    /// primes the agent up front to route *every* build through the queue.
    static let instructions = """
        Build Control Tower serializes builds across all agents on this machine \
        so they don't run at the same time and thrash the CPU — one shared, \
        machine-global queue.

        The build slot is a lease, not a permanent grant: it stays yours only for \
        as long as you keep proving you are alive, by calling build_heartbeat. A \
        ticket that stops checking in is assumed to belong to a crashed agent, and \
        its slot is handed to the next agent in line — who then builds at the same \
        time as you, which is the exact collision this queue exists to prevent. \
        Heartbeats are a requirement of holding the slot, not a courtesy.

        Hold the slot for the build itself and nothing else. Follow this for every \
        build you run (xcodebuild, swift build, or an Xcode build via another tool):
        1. Request the slot only when you are ready to build right now — call \
        request_build as the immediate step before you start the build, not while \
        you still have edits, investigation, or other work to finish first. Pass \
        'agent' (who you are) and 'task' (a short description of what you're \
        building) so a human watching the queue can tell the agents apart. You get \
        a ticket and a disposition.
        2. Build only on GRANTED. If QUEUED, do not build yet; poll build_status \
        with your ticket every ~30-60s until it reports GRANTED.
        3. You MUST call build_heartbeat with your ticket at least once per quoted \
        interval, for the whole time you hold the slot — every time, not only on \
        builds you expect to be long. The GRANTED reply names the interval in \
        seconds and every heartbeat reply repeats it; it is derived from this \
        daemon's own stale-grant window, so do not assume a fixed cadence, use the \
        number you were given.

        Decide how you will do this BEFORE you start the build, because a build \
        launched as a single blocking foreground call leaves you no turn in which \
        to check in — that is the most common way agents lose a slot mid-build. \
        Instead, either start the build in the background with its output going \
        to a unique log file for this build, or run it with a wait/timeout shorter \
        than the quoted interval. Then loop until the build exits: check \
        process/tool status, call build_heartbeat, wait, repeat. If you cannot \
        structure the build so that you can check in on time, do not take the slot \
        yet. Pass a 0-100 'progress' estimate when you can make one cheaply, using \
        elapsed time or a bounded tail/incremental read of the existing log. \
        Omit progress when unknown; a heartbeat does not require fetching a log.

        Use inexpensive models for routine monitoring, not expensive reasoning \
        models. When your client supports delegation and model selection, use \
        one low-cost monitoring agent — for example, Luna at medium reasoning \
        effort — for queue polling, progress checks, heartbeats, and log cleanup. \
        Reuse that monitor for the whole build rather than spawning one per poll; \
        notify the parent when GRANTED, on completion, actionable failure, or a \
        yield/stop request. Hand off the existing ticket, quoted heartbeat \
        interval, build handle, and exact log paths, with one clearly assigned \
        owner for heartbeats, finish_build, and cleanup. Confirm the monitor has \
        the necessary tools and build/log access before handing off. The monitor \
        must not request a second ticket or start another build. If delegation \
        or that model is unavailable, use the lowest-cost suitable option \
        available without delaying or skipping heartbeats.

        Log hygiene is REQUIRED. Do not repeatedly fetch or copy the full build \
        log just to estimate progress. Each GetBuildLog call can create a new \
        multi-megabyte file even when its inline response is filtered. If you do \
        fetch a log, extract only the status/progress or diagnostic lines you need, \
        then immediately delete that call's generated temporary log file and any \
        temporary copies BEFORE the next poll — on success, failure, cancellation, \
        or interruption. Delete only exact temporary paths returned by the tool or \
        created by you; never wildcard-delete logs, Xcode's original logs, or \
        result bundles. Do not delete/truncate a log while the build is still \
        writing it: tail that one file while running, then remove it after the \
        writer exits and you have extracted any needed diagnostics. Keep only a \
        small diagnostic excerpt, not a full log per poll.
        4. Release the slot the moment the build is done or is no longer going to \
        run. Call finish_build when the build ends — success or failure — and also \
        right away if anything stops you from building: you get sidetracked, the \
        build is cancelled, an earlier step fails, or you abandon a queued request. \
        Never hold a ticket while doing unrelated work, and never leave a granted \
        build unfinished.

        In short: request only when ready, build only on GRANTED, heartbeat every \
        interval until the build ends, then finish_build immediately. If you are \
        holding a ticket but not actively building, release it now — you can always \
        request_build again when you are ready. Use queue_status to see who holds \
        the slot and who's waiting. Skipping request_build defeats the purpose for \
        everyone; skipping build_heartbeat costs you the slot while you are still \
        using it.

        Jumping the queue. If your human explicitly tells you a build must run \
        immediately, request_priority_build interrupts whatever is building and \
        gives you the slot. Use it only on that instruction — never because your \
        own work feels urgent. It destroys another agent's in-progress build, and \
        if every agent claims priority the queue stops meaning anything.

        Being asked to yield. The reverse can happen to you: a check-in can come \
        back telling you to stop because a priority build needs your slot. When it \
        does, kill your build immediately and call finish_build — do not finish \
        "just this one thing" first. Your ticket keeps its place at the head of \
        the queue, so you will be granted again shortly and can start over. \
        Ignoring it does not save your build: the slot is taken anyway once the \
        deadline passes, and your build then competes with the priority one for \
        the machine.
        """

    static func makeServer(queue: BuildQueue) async -> Server {
        let server = Server(
            name: "build-control-tower",
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: ToolCatalog.all)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await ToolCatalog.handle(params, queue: queue)
        }

        return server
    }
}
