import Foundation

/// Executable entry point for the Build Control Tower MCP server.
///
/// Runs as a long-lived HTTP daemon on localhost so that every agent on the
/// machine connects to one shared server — and therefore one shared build
/// queue. See `tech-spec.md` for the design; the queue mechanics live in
/// `QueueState` / `BuildQueue`, process detection in `SystemBuildProbe`, and
/// the per-client MCP sessions in `MCPSessionManager`.
@main
struct BuildControlTower {
    static func main() async throws {
        let config = Configuration.fromEnvironment()
        let probe = SystemBuildProbe(cpuThresholdPercent: config.cpuThresholdPercent)
        let queue = BuildQueue(probe: probe, config: config)
        let sessionManager = MCPSessionManager(queue: queue)

        // One safety-net poll drives the single shared queue.
        let pollTask = Task { await queue.runPollLoop() }
        defer { pollTask.cancel() }

        let daemon = HTTPDaemon(
            sessionManager: sessionManager,
            host: "127.0.0.1",
            port: config.port
        )
        try await daemon.run()
    }
}
