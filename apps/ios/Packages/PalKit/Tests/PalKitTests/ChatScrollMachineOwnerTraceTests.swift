import Foundation
import PalChat
import Testing

private struct TraceFrame {
    let millisecondsAfterSend: Int
    let offsetY: Double
    let contentHeight: Double
}

private let container = 683.0
private let insetTop = 55.0
private let insetBottom = 92.0
private let width = 915.5

private let chiefChatSendTrace = [
    TraceFrame(millisecondsAfterSend: 11, offsetY: 53_973, contentHeight: 54_711),
    TraceFrame(millisecondsAfterSend: 12, offsetY: 53_807, contentHeight: 54_545),
    TraceFrame(millisecondsAfterSend: 15, offsetY: 53_807, contentHeight: 54_545),
    TraceFrame(millisecondsAfterSend: 358, offsetY: 53_851, contentHeight: 54_589),
    TraceFrame(millisecondsAfterSend: 359, offsetY: 53_943, contentHeight: 54_589),
    TraceFrame(millisecondsAfterSend: 1_890, offsetY: 53_790, contentHeight: 54_589),
]
private let checkpoints = [100, 500, 1_000, 2_000, 3_000]

private func geometry(_ frame: TraceFrame) -> ChatScrollGeometry {
    ChatScrollGeometry(
        offsetY: frame.offsetY, contentHeight: frame.contentHeight, containerHeight: container, containerWidth: width,
        insetTop: insetTop, insetBottom: insetBottom
    )
}

@Suite("Chat scroll machine owner trace")
struct ChatScrollMachineOwnerTraceTests {
    @Test func theSendInTheChiefChatEndsAtTheBottomAtEveryCheckpoint() {
        var machine = ChatScrollMachine()
        var latest = geometry(TraceFrame(millisecondsAfterSend: 0, offsetY: 53_719, contentHeight: 54_457))
        _ = machine.handle(.rowsChanged((0..<34).map { "row\($0)" }))
        _ = machine.handle(.geometry(latest))
        #expect(machine.handle(.send(animated: true)) == .none)
        _ = machine.handle(.rowsChanged((0..<35).map { "row\($0)" }))
        var distances: [Int: Double] = [:]
        var watch = ChatPinnedShortWatch()
        for frame in chiefChatSendTrace {
            for checkpoint in checkpoints where distances[checkpoint] == nil && checkpoint < frame.millisecondsAfterSend {
                distances[checkpoint] = latest.distanceFromBottom
            }
            latest = geometry(frame)
            var command = machine.handle(.geometry(latest))
            var now = Double(frame.millisecondsAfterSend)
            watch.note(pinned: machine.state == .pinnedToBottom, distance: latest.distanceFromBottom, atMilliseconds: now)
            while case .scrollToBottom = command {
                now += ChatPinnedShortWatch.frameMilliseconds
                latest.offsetY = latest.contentHeight - container - insetTop
                command = machine.handle(.geometry(latest))
                watch.note(pinned: machine.state == .pinnedToBottom, distance: latest.distanceFromBottom, atMilliseconds: now)
            }
            #expect(
                machine.state != .pinnedToBottom || latest.distanceFromBottom <= ChatScrollMachine.atBottomTolerance,
                "pinned \(Int(latest.distanceFromBottom)) pt short at \(frame.millisecondsAfterSend) ms with no repair"
            )
        }
        for checkpoint in checkpoints where distances[checkpoint] == nil { distances[checkpoint] = latest.distanceFromBottom }
        for checkpoint in checkpoints {
            #expect((distances[checkpoint] ?? .infinity) <= ChatScrollMachine.atBottomTolerance, "\(checkpoint) ms after the send")
        }
        #expect(machine.state == .pinnedToBottom)
        #expect(!machine.showsJumpButton)
        #expect(watch.overdue(atMilliseconds: 3_000) == nil)
        #expect(watch.episodes == 0)
    }
}
