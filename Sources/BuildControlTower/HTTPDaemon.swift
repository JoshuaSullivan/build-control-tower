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
    let port: Int

    /// The endpoint all MCP traffic uses, e.g. `http://127.0.0.1:7373/mcp`.
    static let path = "mcp"

    /// Upper bound on a buffered request body. MCP messages are small.
    private static let maxBodySize = 1 << 20  // 1 MiB

    func run() async throws {
        let router = Router()
        let manager = sessionManager
        let route = RouterPath(stringLiteral: Self.path)

        // Every MCP method (POST for messages, GET for the SSE stream, DELETE to
        // end a session) routes through the same bridge.
        router.post(route) { request, _ in try await Self.respond(to: request, using: manager) }
        router.get(route) { request, _ in try await Self.respond(to: request, using: manager) }
        router.delete(route) { request, _ in try await Self.respond(to: request, using: manager) }

        logStartup()

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port))
        )
        try await app.runService()
    }

    // MARK: - Request handling

    private static func respond(to request: Request, using manager: MCPSessionManager) async throws -> Response {
        let daemonRequest = try await makeDaemonRequest(request)
        let daemonResponse = await manager.handle(daemonRequest)
        return makeResponse(daemonResponse)
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
        let message = "Build Control Tower listening on http://\(host):\(port)/\(Self.path)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}
