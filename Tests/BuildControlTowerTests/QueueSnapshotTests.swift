import Foundation
import Testing

@testable import BuildControlTower

/// Tests for the `/status` JSON contract. The snapshot types are what an
/// out-of-band monitor parses, so the encoded key set is a published interface —
/// these tests pin it, including the deliberate omission of the computed `label`.
struct QueueSnapshotTests {
    private func encoded(_ snapshot: QueueSnapshot) -> [String: Any] {
        let data = try? JSONEncoder().encode(snapshot)
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return object as? [String: Any] ?? [:]
    }

    @Test func activeEntryPublishesProgressAndAges() {
        let snapshot = QueueSnapshot(
            active: ActiveEntry(
                id: UUID(),
                agent: "claude-A",
                task: "xcodebuild Teams iOS",
                progress: 45,
                elapsedSeconds: 90,
                secondsSinceHeartbeat: 20
            ),
            waiting: []
        )

        let active = encoded(snapshot)["active"] as? [String: Any] ?? [:]

        #expect(active["agent"] as? String == "claude-A")
        #expect(active["task"] as? String == "xcodebuild Teams iOS")
        #expect(active["progress"] as? Int == 45)
        #expect(active["elapsedSeconds"] as? Int == 90)
        #expect(active["secondsSinceHeartbeat"] as? Int == 20)
        // `label` is presentation only — monitors compose their own from the parts.
        #expect(active["label"] == nil)
    }

    @Test func waitingEntryPublishesTaskAndAge() {
        let snapshot = QueueSnapshot(
            active: nil,
            waiting: [WaitingEntry(id: UUID(), agent: "claude-B", task: "swift test", waitingSeconds: 240)]
        )

        let waiting = (encoded(snapshot)["waiting"] as? [[String: Any]] ?? []).first ?? [:]

        #expect(waiting["agent"] as? String == "claude-B")
        #expect(waiting["task"] as? String == "swift test")
        #expect(waiting["waitingSeconds"] as? Int == 240)
        #expect(waiting["label"] == nil)
    }

    @Test func unreportedProgressIsOmittedRatherThanZero() {
        let snapshot = QueueSnapshot(
            active: ActiveEntry(
                id: UUID(),
                agent: nil,
                task: nil,
                progress: nil,
                elapsedSeconds: 5,
                secondsSinceHeartbeat: 5
            ),
            waiting: []
        )

        let active = encoded(snapshot)["active"] as? [String: Any] ?? [:]

        // A monitor must be able to tell "no estimate yet" from "0% done".
        #expect(active["progress"] == nil)
        #expect(active["elapsedSeconds"] as? Int == 5)
    }

    @Test func descriptionShowsWhoIsBuildingWhatAndHowFar() {
        let snapshot = QueueSnapshot(
            active: ActiveEntry(
                id: UUID(),
                agent: "claude-A",
                task: "xcodebuild Teams iOS",
                progress: 45,
                elapsedSeconds: 90,
                secondsSinceHeartbeat: 20
            ),
            waiting: [WaitingEntry(id: UUID(), agent: nil, task: nil, waitingSeconds: 30)]
        )

        let text = snapshot.description

        #expect(text.contains("claude-A — xcodebuild Teams iOS"))
        #expect(text.contains("45%"))
        #expect(text.contains("updated 20s ago"))
        #expect(text.contains("1m elapsed"))
        #expect(text.contains("unnamed"))
        #expect(text.contains("waiting 30s"))
    }
}
