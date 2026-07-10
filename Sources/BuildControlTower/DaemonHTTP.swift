import Foundation

/// Framework-neutral HTTP request passed from the Hummingbird layer
/// (`HTTPDaemon`) to the MCP layer (`MCPSessionManager`).
///
/// The MCP SDK and `swift-http-types` both define `HTTPRequest`/`HTTPResponse`.
/// Bridging through these plain types keeps the two modules in separate files
/// so neither has to import — and disambiguate against — the other.
struct DaemonRequest: Sendable {
    let method: String
    let headers: [String: String]
    let body: Data?
}

/// Framework-neutral HTTP response passed back from the MCP layer.
struct DaemonResponse: Sendable {
    /// The response body, which may be buffered or a live SSE stream.
    enum Body: Sendable {
        case none
        case data(Data)
        case stream(AsyncThrowingStream<Data, any Error>)
    }

    let status: Int
    let headers: [String: String]
    let body: Body
}
