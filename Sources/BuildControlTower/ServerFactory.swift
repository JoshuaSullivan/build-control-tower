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

        Follow this for every build you run (xcodebuild, swift build, or an Xcode \
        build via another tool):
        1. Before building, call request_build — you get a ticket and a disposition.
        2. Build only on GRANTED. If QUEUED, do not build yet; poll build_status \
        with your ticket every ~30-60s until it reports GRANTED.
        3. Always call finish_build when the build ends — success or failure — to \
        release the slot. Call it too if you abandon a queued request. Never leave \
        a granted build unfinished.

        Use queue_status to see who holds the slot and who's waiting. Skipping \
        request_build defeats the purpose for everyone.
        """

    static func makeServer(queue: BuildQueue) async -> Server {
        let server = Server(
            name: "build-control-tower",
            version: "0.1.3",
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
