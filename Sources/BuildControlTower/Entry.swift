import Foundation
import MCP

/// Executable entry point for the Build Control Tower MCP server.
///
/// Serializes builds across concurrent agents so they don't overload the
/// machine. See `tech-spec.md` for the design; the queue mechanics live in
/// `QueueState` / `BuildQueue` and the process detection in `SystemBuildProbe`.
@main
struct BuildControlTower {
    static func main() async throws {
        let config = Configuration.fromEnvironment()
        let probe = SystemBuildProbe(cpuThresholdPercent: config.cpuThresholdPercent)
        let queue = BuildQueue(probe: probe, config: config)

        let server = await ServerFactory.makeServer(queue: queue)
        let transport = StdioTransport()
        try await server.start(transport: transport)

        // Background safety net; the transport keeps the process alive.
        let pollTask = Task { await queue.runPollLoop() }
        await server.waitUntilCompleted()
        pollTask.cancel()
    }
}
