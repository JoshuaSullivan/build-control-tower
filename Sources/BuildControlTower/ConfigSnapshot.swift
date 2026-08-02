import Foundation

/// The tuning actually in force, rendered for the read-only `/config` endpoint.
///
/// The queue's timing policy is set per-install from the environment, so a
/// monitor that hardcodes the defaults silently disagrees with any daemon
/// launched with `BCT_GRACE_SECONDS`. Publishing the effective values lets a
/// monitor derive its own staleness thresholds from what this daemon will
/// actually do, rather than from what it usually does.
///
/// Durations are plain second counts for the same reason `QueueSnapshot` uses
/// them: `Duration`'s synthesized encoding is an opaque components pair that
/// consumers would have to special-case.
///
/// Unlike `QueueSnapshot`, this is immutable for the daemon's lifetime — a
/// client can fetch it once and re-fetch only after a reconnect, which is the
/// only moment it could have changed.
struct ConfigSnapshot: Sendable, Encodable, Equatable {
    /// The server version, matching what MCP `initialize` reports. Lets a client
    /// tell which feature generation of the daemon it is talking to.
    let version: String

    /// The port this daemon is listening on.
    let port: Int

    /// How often the background safety-net loop reconciles the queue.
    let pollSeconds: Int

    /// How long a grant may go silent, with no build CPU observed, before it is
    /// reclaimed. The upper bound on "quiet but still legitimately building".
    let staleGrantGraceSeconds: Int

    /// The check-in cadence agents are asked to keep. A client can treat silence
    /// beyond this as the first sign an agent has stopped reporting, well before
    /// the grant is actually at risk.
    let recommendedHeartbeatSeconds: Int

    /// Combined `%CPU` above which the probe considers a build to be running.
    let cpuThresholdPercent: Double

    /// Project a `Configuration` into its published form.
    ///
    /// - Parameters:
    ///   - config: the tuning in force.
    ///   - version: the server version to advertise.
    init(_ config: Configuration, version: String = ServerFactory.version) {
        self.version = version
        self.port = config.port
        self.pollSeconds = Self.seconds(config.pollInterval)
        self.staleGrantGraceSeconds = Self.seconds(config.staleGrantGrace)
        self.recommendedHeartbeatSeconds = Self.seconds(config.recommendedHeartbeatInterval)
        self.cpuThresholdPercent = config.cpuThresholdPercent
    }

    /// Whole seconds in a duration, dropping any sub-second remainder.
    private static func seconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds)
    }
}
