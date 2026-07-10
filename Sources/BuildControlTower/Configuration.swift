import Foundation

/// Tunable parameters for the control tower. Defaults are sensible for a
/// laptop running one or two agents; all three can be overridden at launch via
/// environment variables so the server can be retuned without recompiling.
struct Configuration: Sendable {
    /// How often the background safety-net loop reconciles the queue. This is
    /// the *upper bound* on how long a freed slot goes unclaimed when nothing
    /// else drives a reconcile (e.g. all agents crashed). The fast path
    /// (explicit `finish_build`) advances the queue immediately regardless.
    var pollInterval: Duration

    /// How long a grant may sit apparently idle (no build CPU observed) before
    /// the poll reclaims it, assuming the agent crashed or never reported done.
    /// Must exceed `pollInterval` so a slow-to-start build isn't mistaken for a
    /// dead agent — `fromEnvironment` enforces this.
    var staleGrantGrace: Duration

    /// Combined `%CPU` across compiler/linker processes above which a build is
    /// considered "actively running" by `SystemBuildProbe`.
    var cpuThresholdPercent: Double

    /// TCP port the daemon listens on (always bound to 127.0.0.1).
    var port: Int

    static let `default` = Configuration(
        pollInterval: .seconds(120),
        staleGrantGrace: .seconds(360),
        cpuThresholdPercent: 40,
        port: 7373
    )

    /// Reads overrides from `BCT_POLL_SECONDS`, `BCT_GRACE_SECONDS`, and
    /// `BCT_CPU_THRESHOLD`. Missing or invalid values fall back to defaults.
    static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Configuration {
        var pollSeconds = 120
        var graceSeconds = 360
        var threshold = 40.0
        var port = 7373

        if let raw = env["BCT_POLL_SECONDS"], let value = Int(raw), value > 0 {
            pollSeconds = value
        }
        if let raw = env["BCT_GRACE_SECONDS"], let value = Int(raw), value > 0 {
            graceSeconds = value
        }
        if let raw = env["BCT_CPU_THRESHOLD"], let value = Double(raw), value > 0 {
            threshold = value
        }
        if let raw = env["BCT_PORT"], let value = Int(raw), (1...65535).contains(value) {
            port = value
        }

        // Design invariant: the grace window must be longer than one poll
        // interval, otherwise a build still in its low-CPU startup phase could
        // be reclaimed as if the agent had died.
        if graceSeconds <= pollSeconds {
            graceSeconds = pollSeconds * 3
        }

        return Configuration(
            pollInterval: .seconds(pollSeconds),
            staleGrantGrace: .seconds(graceSeconds),
            cpuThresholdPercent: threshold,
            port: port
        )
    }
}
