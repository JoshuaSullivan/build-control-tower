import Foundation
import MCP

/// Builds the MCP `Server` and wires its method handlers to the `BuildQueue`.
enum ServerFactory {
    /// Server-level guidance sent to clients in the `initialize` response. Unlike
    /// the per-tool descriptions (seen only once an agent inspects a tool), this
    /// primes the agent up front to route *every* build through the queue.
    static let instructions = """
        Build Control Tower serializes builds across all agents on this machine \
        so they don't run at the same time and thrash the CPU — one shared, \
        machine-global queue.

        Hold the slot for the build itself and nothing else. Follow this for every \
        build you run (xcodebuild, swift build, or an Xcode build via another tool):
        1. Request the slot only when you are ready to build right now — call \
        request_build as the immediate step before you start the build, not while \
        you still have edits, investigation, or other work to finish first. You get \
        a ticket and a disposition.
        2. Build only on GRANTED. If QUEUED, do not build yet; poll build_status \
        with your ticket every ~30-60s until it reports GRANTED.
        3. Release the slot the moment the build is done or is no longer going to \
        run. Call finish_build when the build ends — success or failure — and also \
        right away if anything stops you from building: you get sidetracked, the \
        build is cancelled, an earlier step fails, or you abandon a queued request. \
        Never hold a ticket while doing unrelated work, and never leave a granted \
        build unfinished.

        If you are holding a ticket but not actively building, release it now — you \
        can always request_build again when you are ready. Use queue_status to see \
        who holds the slot and who's waiting. Skipping request_build defeats the \
        purpose for everyone.
        """

    static func makeServer(queue: BuildQueue) async -> Server {
        let server = Server(
            name: "build-control-tower",
            version: "0.1.4",
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
