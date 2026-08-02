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
    }

    @Test func publishesExactlyTheDocumentedKeys() {
        let json = encoded(ConfigSnapshot(.default))

        #expect(
            Set(json.keys) == [
                "version", "port", "pollSeconds", "staleGrantGraceSeconds",
                "recommendedHeartbeatSeconds", "cpuThresholdPercent",
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
}
