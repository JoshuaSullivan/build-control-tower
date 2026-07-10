import Foundation
import MCP

/// Builds the MCP `Server` and wires its method handlers to the `BuildQueue`.
enum ServerFactory {
    static func makeServer(queue: BuildQueue) async -> Server {
        let server = Server(
            name: "build-control-tower",
            version: "0.1.0",
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
