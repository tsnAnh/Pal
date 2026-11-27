#if os(macOS)
import PalChat
import Testing

@testable import Pal

@MainActor
@Suite("Mac chat send follow", .serialized)
struct MacChatSendFollowTests {
    static let admission = Duration.seconds(6)
    nonisolated static let shapes = [
        SendFollowShape(name: "long idle", history: 40, running: false),
        SendFollowShape(name: "long running", history: 40, running: true),
        SendFollowShape(name: "short idle after a trackpad scroll", history: 0, running: false, scrollsFirst: true),
        SendFollowShape(name: "long idle after a trackpad scroll", history: 40, running: false, scrollsFirst: true),
        SendFollowShape(name: "long running after a trackpad scroll", history: 40, running: true, scrollsFirst: true),
    ]

    @Test("two quick sends draw at once and the pinned list follows them while admission takes 6 s", arguments: shapes)
    func sendsDrawAndFollow(shape: SendFollowShape) async throws {
        let stage = try await SendFollowStage(shape: shape, admission: Self.admission)
        defer { stage.close() }
        var measures: [SendFollowMeasure] = []
        for count in 1...SendFollowStage.texts.count {
            measures.append(try await stage.send(count, startsTurn: !shape.running && count == 1))
        }
        let final = try await stage.takeServerRows(running: shape.running)
        let report = measures.map { "\(shape.name) \($0.line)" }
        for line in report { print("SENDFOLLOW \(line)") }
        var failures = measures.flatMap(\.failures)
        if final.rowOrder != SendFollowStage.texts { failures.append("after the server rows: \(final.rowOrder)") }
        if !final.isAtNewest || final.button { failures.append("after the server rows: distance \(final.distance) button \(final.button)") }
        #expect(failures.isEmpty, Comment(rawValue: (failures + report).joined(separator: "\n")))
    }
}
#endif
