import Foundation
import MCP

/// Owns the single shared `BuildQueue` and one MCP `Server` + stateful HTTP
/// transport per client session.
///
/// This is what makes the daemon a true control tower: every agent that
/// connects gets its own MCP session (so JSON-RPC ids and SSE streams stay
/// isolated per client), but all sessions share the same `BuildQueue`, so the
/// agents coordinate through one global queue.
actor MCPSessionManager {
    private struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
    }

    private let queue: BuildQueue
    private var sessions: [String: Session] = [:]

    init(queue: BuildQueue) {
        self.queue = queue
    }

    /// Number of live sessions (diagnostics/tests).
    var sessionCount: Int { sessions.count }

    /// Route one HTTP request to the correct session — creating a session on an
    /// `initialize` POST — and return the response for the HTTP layer to send.
    func handle(_ request: DaemonRequest) async -> DaemonResponse {
        let method = request.method.uppercased()

        if let sessionID = header(request, HTTPHeaderName.sessionID),
            let session = sessions[sessionID]
        {
            let response = await session.transport.handleRequest(sdkRequest(request))
            if method == "DELETE" {
                sessions[sessionID] = nil
                await teardown(session)
            }
            return convert(response)
        }

        // No known session. A POST with no session id must be an `initialize`
        // request; give it a fresh session. Anything else is a protocol error
        // (a stale session id, or a GET/DELETE without a session).
        if header(request, HTTPHeaderName.sessionID) == nil, method == "POST" {
            return await startSession(with: request)
        }

        return convert(.error(statusCode: 404, .invalidRequest("Unknown or missing MCP session")))
    }

    // MARK: - Session lifecycle

    private func startSession(with request: DaemonRequest) async -> DaemonResponse {
        let transport = StatefulHTTPServerTransport()
        let server = await ServerFactory.makeServer(queue: queue)

        do {
            try await server.start(transport: transport)
        } catch {
            await transport.disconnect()
            return convert(.error(statusCode: 500, .internalError("Failed to start MCP session")))
        }

        let response = await transport.handleRequest(sdkRequest(request))

        // The transport assigns a session id only on a successful initialize;
        // keep the session if it did, otherwise tear it back down.
        if let assigned = response.headers[HTTPHeaderName.sessionID] {
            sessions[assigned] = Session(server: server, transport: transport)
        } else {
            await teardown(Session(server: server, transport: transport))
        }
        return convert(response)
    }

    private func teardown(_ session: Session) async {
        await session.transport.disconnect()
        await session.server.stop()
    }

    // MARK: - Conversions between neutral and SDK types

    private func sdkRequest(_ request: DaemonRequest) -> HTTPRequest {
        HTTPRequest(method: request.method, headers: request.headers, body: request.body, path: nil)
    }

    private func convert(_ response: HTTPResponse) -> DaemonResponse {
        let body: DaemonResponse.Body
        switch response {
        case .stream(let stream, _):
            body = .stream(stream)
        default:
            body = response.bodyData.map(DaemonResponse.Body.data) ?? .none
        }
        return DaemonResponse(status: response.statusCode, headers: response.headers, body: body)
    }

    private func header(_ request: DaemonRequest, _ name: String) -> String? {
        let lowered = name.lowercased()
        return request.headers.first { $0.key.lowercased() == lowered }?.value
    }
}
