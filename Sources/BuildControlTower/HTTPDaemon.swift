import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// The long-running HTTP daemon. Listens on localhost and bridges Hummingbird
/// requests to the shared `MCPSessionManager`, which speaks MCP.
///
/// This file is the only one that imports Hummingbird; it translates between
/// Hummingbird's request/response types and the neutral `DaemonRequest` /
/// `DaemonResponse`, keeping the MCP SDK out of the Hummingbird namespace.
struct HTTPDaemon {
    let sessionManager: MCPSessionManager
    let host: String

    /// The tuning in force, for the listen port and the startup log.
    let config: Configuration

    /// Supplies a fresh queue snapshot for the read-only `/status` endpoint.
    /// A closure (rather than the `BuildQueue` actor itself) keeps the actor out
    /// of this struct's stored state while staying `Sendable`.
    let snapshotProvider: @Sendable () async -> QueueSnapshot

    /// Raises a waiting ticket to priority for the `/promote` endpoint, yielding
    /// the updated queue, or `nil` when no waiting ticket carries that id. A
    /// closure for the same reason as `snapshotProvider`.
    let promoteHandler: @Sendable (UUID) async -> QueueSnapshot?

    /// The endpoint all MCP traffic uses, e.g. `http://127.0.0.1:7373/mcp`.
    static let path = "mcp"

    /// The read-only JSON status endpoint, e.g. `http://127.0.0.1:7373/status`.
    /// Used by out-of-band monitors (e.g. the menu-bar app) that just want to
    /// poll queue state without speaking MCP.
    static let statusPath = "status"

    /// The read-only JSON configuration endpoint, e.g.
    /// `http://127.0.0.1:7373/config`. Publishes the timing policy in force so a
    /// monitor can derive staleness thresholds from this daemon's actual tuning
    /// instead of assuming the defaults.
    static let configPath = "config"

    /// The one *mutating* endpoint, e.g. `http://127.0.0.1:7373/promote`.
    /// `POST {"ticket": "<uuid>"}` raises a waiting build to priority, which
    /// pre-empts whatever is running. It exists so the monitor app can offer a
    /// "build this next" affordance to the human without speaking MCP.
    ///
    /// Unauthenticated, like the read-only endpoints, and safe on the same
    /// grounds: the listener is bound to `127.0.0.1`, so the caller is already
    /// running as this user on this machine and could stop the daemon outright.
    static let promotePath = "promote"

    /// Upper bound on a buffered request body. MCP messages are small.
    private static let maxBodySize = 1 << 20  // 1 MiB

    func run() async throws {
        let router = Router()
        let manager = sessionManager
        let provideSnapshot = snapshotProvider
        let promote = promoteHandler
        let route = RouterPath(stringLiteral: Self.path)
        let statusRoute = RouterPath(stringLiteral: Self.statusPath)
        let configRoute = RouterPath(stringLiteral: Self.configPath)
        let promoteRoute = RouterPath(stringLiteral: Self.promotePath)

        // The tuning cannot change while the process lives, so it is rendered
        // once here rather than rebuilt per request.
        let configSnapshot = ConfigSnapshot(config)

        // Every MCP method (POST for messages, GET for the SSE stream, DELETE to
        // end a session) routes through the same bridge.
        router.post(route) { request, _ in try await Self.respond(to: request, using: manager) }
        router.get(route) { request, _ in try await Self.respond(to: request, using: manager) }
        router.delete(route) { request, _ in try await Self.respond(to: request, using: manager) }

        // Read-only JSON snapshot for out-of-band monitors. No MCP session.
        router.get(statusRoute) { _, _ in try await Self.status(provideSnapshot) }

        // The timing policy this daemon was launched with. Also read-only and
        // session-free; a monitor fetches it once and again after a reconnect.
        router.get(configRoute) { _, _ in try Self.json(configSnapshot) }

        // Promote a waiting build to priority on a human's instruction. The one
        // endpoint that changes queue state, and still session-free — the
        // monitor identifies the build by ticket id from `/status`.
        router.post(promoteRoute) { request, _ in try await Self.promote(request, using: promote) }

        logStartup()

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: config.port))
        )
        try await app.runService()
    }

    // MARK: - Request handling

    private static func respond(to request: Request, using manager: MCPSessionManager) async throws -> Response {
        let daemonRequest = try await makeDaemonRequest(request)
        let daemonResponse = await manager.handle(daemonRequest)
        return makeResponse(daemonResponse)
    }

    /// Serialize the current queue snapshot as JSON for the `/status` endpoint.
    private static func status(_ provideSnapshot: @Sendable () async -> QueueSnapshot) async throws -> Response {
        try json(await provideSnapshot())
    }

    /// The body of a `POST /promote` request.
    private struct PromoteRequest: Decodable {
        let ticket: UUID
    }

    /// Raise a waiting build to priority and return the resulting queue.
    ///
    /// Distinguishes the two ways this can fail so the monitor can react
    /// sensibly: `400` means the caller sent something malformed, while `404`
    /// means the ticket simply isn't waiting any more — it finished, or it is
    /// already the build holding the slot — which is a race the monitor should
    /// absorb by refreshing rather than report as a fault.
    private static func promote(
        _ request: Request,
        using promote: @Sendable (UUID) async -> QueueSnapshot?
    ) async throws -> Response {
        var mutableRequest = request
        let buffer = try await mutableRequest.collectBody(upTo: maxBodySize)
        guard let body = try? JSONDecoder().decode(PromoteRequest.self, from: Data(buffer.readableBytesView)) else {
            return Response(status: .badRequest)
        }
        guard let snapshot = await promote(body.ticket) else {
            return Response(status: .notFound)
        }
        return try json(snapshot)
    }

    /// Render a value as a `200 application/json` response.
    ///
    /// A default `JSONEncoder` on purpose: the read-only endpoints publish
    /// camelCase keys exactly as declared, and omit nil optionals rather than
    /// encoding them as `null`.
    private static func json(_ value: some Encodable) throws -> Response {
        let data = try JSONEncoder().encode(value)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    private static func makeDaemonRequest(_ request: Request) async throws -> DaemonRequest {
        var headers: [String: String] = [:]
        for field in request.headers {
            headers[field.name.canonicalName] = field.value
        }

        var mutableRequest = request
        let buffer = try await mutableRequest.collectBody(upTo: maxBodySize)
        let body = buffer.readableBytes > 0 ? Data(buffer.readableBytesView) : nil

        return DaemonRequest(method: request.method.rawValue, headers: headers, body: body)
    }

    private static func makeResponse(_ response: DaemonResponse) -> Response {
        var fields = HTTPFields()
        for (name, value) in response.headers {
            if let fieldName = HTTPField.Name(name) {
                fields[fieldName] = value
            }
        }
        let status = HTTPResponse.Status(code: response.status)

        switch response.body {
        case .none:
            return Response(status: status, headers: fields)
        case .data(let data):
            return Response(status: status, headers: fields, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
        case .stream(let stream):
            // Re-yield the SDK's SSE `Data` chunks as ByteBuffers. An explicit
            // stream (rather than `.map`) keeps the element type Sendable for
            // Hummingbird's ResponseBody under strict concurrency.
            let buffers = AsyncThrowingStream<ByteBuffer, any Error> { continuation in
                let task = Task {
                    do {
                        for try await chunk in stream {
                            continuation.yield(ByteBuffer(bytes: chunk))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return Response(status: status, headers: fields, body: ResponseBody(asyncSequence: buffers))
        }
    }

    private func logStartup() {
        let base = "http://\(host):\(config.port)"
        let message = """
            Build Control Tower listening on \(base)/\(Self.path) \
            (status: \(base)/\(Self.statusPath), config: \(base)/\(Self.configPath), \
            promote: \(base)/\(Self.promotePath))
            Configuration: \(config.summary)

            """
        FileHandle.standardError.write(Data(message.utf8))
    }
}
