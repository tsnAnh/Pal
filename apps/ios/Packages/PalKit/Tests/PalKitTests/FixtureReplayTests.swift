import Foundation
import PalChat
import PalProtocol
import PalTransport
import Testing

@Suite("Recorded gateway traffic")
struct FixtureReplayTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ios-client")

    static var fixtures: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func recordedFixturesExist() {
        #expect(Self.fixtures.count >= 4, "regenerate with Scripts/run-e2e")
    }

    @Test(arguments: FixtureReplayTests.fixtures)
    func replayingInboundFramesReproducesTheRecordedTranscript(fixture: URL) throws {
        let lines = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n")
        var replayers: [String: TranscriptReplayer] = [:]
        var expected: [String: Transcript.Summary] = [:]
        var frames = 0
        for line in lines {
            let record = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            let client = try #require(record["client"]?.stringValue)
            switch record["kind"]?.stringValue {
            case "frame":
                let direction: FrameDirection = record["dir"]?.stringValue == "in" ? .inbound : .outbound
                let data = try JSONEncoder().encode(try #require(record["frame"]))
                replayers[client, default: TranscriptReplayer()].feed(direction, try RPCCodec.decode(data))
                frames += 1
            case "expected":
                expected[client] = try #require(record["summary"]).decoded(as: Transcript.Summary.self)
            default:
                Issue.record("unknown fixture record")
            }
        }
        #expect(frames > 0)
        for (client, summary) in expected {
            let replayed = try #require(replayers[client]).transcript.summary()
            #expect(
                replayed == summary,
                "replay of \(fixture.lastPathComponent) client \(client) diverged: replayed \(replayed.items.map { "\($0.kind):\($0.text.count)" }) recorded \(summary.items.map { "\($0.kind):\($0.text.count)" })"
            )
        }
    }
}
