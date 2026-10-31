import Foundation
import Testing

@testable import BuildControlTower

/// Tests for the `/config` JSON contract. Like `QueueSnapshot`, this is parsed by
/// out-of-band monitors, so the encoded key set is a published interface — these
/// tests pin it, and pin that the durations are published as plain second counts
/// rather than `Duration`'s opaque components pair.
struct ConfigSnapshotTests {
    private func encoded(_ snapshot: ConfigSnapshot) -> [String: Any] {
        let data = try? JSONEncoder().encode(snapshot)
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return object as? [String: Any] ?? [:]
    }

    @Test func publishesTheTuningInForce() {
        let snapshot = ConfigSnapshot(.default, version: "0.3.0")

        let json = encoded(snapshot)

        #expect(json["version"] as? String == "0.3.0")
        #expect(json["port"] as? Int == 7373)
        #expect(json["pollSeconds"] as? Int == 120)
        #expect(json["staleGrantGraceSeconds"] as? Int == 360)
        #expect(json["recommendedHeartbeatSeconds"] as? Int == 120)
        #expect(json["cpuThresholdPercent"] as? Double == 40)
        #expect(json["yieldDeadlineSeconds"] as? Int == 180)
    }

    @Test func publishesExactlyTheDocumentedKeys() {
        let json = encoded(ConfigSnapshot(.default))

        #expect(
            Set(json.keys) == [
                "version", "port", "pollSeconds", "staleGrantGraceSeconds",
                "recommendedHeartbeatSeconds", "cpuThresholdPercent",
                "yieldDeadlineSeconds",
            ]
        )
    }

    @Test func heartbeatCadenceTracksANonDefaultGrace() {
        // The whole point of the endpoint: a retuned daemon must publish its own
        // cadence, not the default, so a monitor's thresholds follow it.
        let config = Configuration(
            pollInterval: .seconds(10),
            staleGrantGrace: .seconds(90),
            cpuThresholdPercent: 40,
            yieldDeadline: .seconds(45),
            port: 7373
        )

        let snapshot = ConfigSnapshot(config)

        #expect(snapshot.staleGrantGraceSeconds == 90)
        #expect(snapshot.recommendedHeartbeatSeconds == 30)
    }

    @Test func advertisedVersionMatchesTheMCPServerVersion() {
        // The two are read from one constant precisely so they cannot drift; if
        // this ever fails, a client feature-detecting over HTTP would be lied to.
        #expect(ConfigSnapshot(.default).version == ServerFactory.version)
    }

    // MARK: - Yield deadline

    @Test func yieldDeadlineDefaultsToOneAndAHalfHeartbeats() {
        let config = Configuration.fromEnvironment([:])

        // One check-in to hear the request, plus margin to act on it.
        #expect(config.recommendedHeartbeatInterval == .seconds(120))
        #expect(config.yieldDeadline == .seconds(180))
    }

    @Test func yieldDeadlineTracksARetunedGrace() {
        let config = Configuration.fromEnvironment(["BCT_GRACE_SECONDS": "900"])

        #expect(config.recommendedHeartbeatInterval == .seconds(300))
        #expect(config.yieldDeadline == .seconds(450))
    }

    @Test func yieldDeadlineHonoursAnExplicitOverride() {
        let config = Configuration.fromEnvironment(["BCT_YIELD_SECONDS": "240"])

        #expect(config.yieldDeadline == .seconds(240))
    }

    @Test func yieldDeadlineIsFlooredAtOneHeartbeatInterval() {
        // Below one check-in the slot would be seized before the holder could
        // possibly have been told to release it — the cooperative handoff would
        // never happen and every pre-emption would overlap two builds.
        let config = Configuration.fromEnvironment(["BCT_YIELD_SECONDS": "5"])

        #expect(config.yieldDeadline == config.recommendedHeartbeatInterval)
        #expect(config.yieldDeadline == .seconds(120))
    }

    @Test func summaryReportsTheYieldDeadline() {
        // The daemon logs this at startup; it is how an operator discovers the
        // tuning of a long-running process.
        #expect(Configuration.default.summary.contains("yield deadline 180s"))
    }
}
