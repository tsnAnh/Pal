import Foundation
import Testing

@testable import HermesBots
@testable import PalChat

@MainActor
private final class RebuildScript {
    typealias Move = @MainActor (RebuildScript) -> Void

    let harness: RebuildHarness
    var generator: RebuildSplitMix
    var clock: TimeInterval = 500
    var serial = 0
    var text = "Hello"

    init(seed: UInt64) throws {
        generator = RebuildSplitMix(state: seed)
        harness = try RebuildHarness(world: rebuildConversation())
    }

    static let moves: [(weight: Int, move: Move)] = [
        (55, { $0.grow() }), (7, { $0.appendStreaming() }), (6, { $0.appendUser() }), (4, { $0.prependPage() }),
        (5, { $0.editEarlier() }), (4, { $0.deleteEarlier() }), (4, { $0.appendClarify() }), (3, { $0.appendHidden() }),
        (3, { $0.appendDuplicate() }), (3, { $0.changePhase() }), (3, { $0.flipStreaming() }), (3, { $0.harness.world.isRunning.toggle() }),
    ]

    func pick() -> Move {
        var roll = Int.random(in: 0..<Self.moves.reduce(0) { $0 + $1.weight }, using: &generator)
        for entry in Self.moves {
            if roll < entry.weight { return entry.move }
            roll -= entry.weight
        }
        return Self.moves[0].move
    }

    func stamp() -> Date? {
        clock += [5, 30, 400, 4000, 90_000].randomElement(using: &generator) ?? 5
        return Int.random(in: 0..<10, using: &generator) == 0 ? nil : rebuildAt(clock)
    }

    func grow() {
        text += " t\(serial)"
        guard case .assistant = harness.world.rows.last?.item.content else { return }
        harness.world.editLast { $0.content = .assistant(text: text, reasoning: "", isStreaming: true) }
    }

    func appendStreaming() {
        text = "n\(serial)"
        harness.world.append(rebuildAssistant("a\(serial)", text, streaming: true, at: stamp()))
    }

    func appendUser() {
        let delivery = [TranscriptItem.Delivery.sent, .sending, .queued].randomElement(using: &generator) ?? .sent
        harness.world.append(rebuildUser("u\(serial)", "question \(serial)", delivery: delivery, at: stamp()))
    }

    func prependPage() {
        let age = -Double(serial) * 100
        harness.world.prepend([
            rebuildUser("o\(serial)", "older \(serial)", at: rebuildAt(age)),
            rebuildAssistant("p\(serial)", "older reply", at: rebuildAt(age + 5)),
        ])
    }

    func editEarlier() {
        let count = harness.world.rows.count
        guard count > 2 else { return }
        let index = Int.random(in: 0..<(count - 1), using: &generator)
        guard case .user = harness.world.rows[index].item.content else { return }
        harness.world.rows[index].item.content = .user(text: "edited \(serial)", delivery: .sent)
    }

    func deleteEarlier() {
        let count = harness.world.rows.count
        guard count > 3 else { return }
        harness.world.rows.remove(at: Int.random(in: 0..<(count - 1), using: &generator))
    }

    func appendClarify() {
        harness.world.append(rebuildAnswered("c\(serial / 3)", serial, "q\(serial)", at: stamp()))
    }

    func appendHidden() {
        text = ["[SILENT]", "", "  ", "plain"].randomElement(using: &generator) ?? ""
        harness.world.append(rebuildAssistant("s\(serial)", text, streaming: true, at: stamp()))
    }

    func appendDuplicate() {
        harness.world.append(rebuildAssistant("a1", "dup \(serial)", streaming: true, at: stamp()))
    }

    func changePhase() {
        let phases: [ChatPhase] = [.live(lastSequence: serial, replayEpoch: "e"), .resyncing, .attaching, .detached]
        harness.phase(phases.randomElement(using: &generator) ?? .detached, "phase \(serial)")
    }

    func flipStreaming() {
        harness.world.editLast { item in
            guard case .assistant(let body, _, let streaming) = item.content else { return }
            item.content = .assistant(text: body, reasoning: "r\(serial)", isStreaming: !streaming)
        }
    }

    func run(steps: Int) {
        harness.push("initial")
        for step in 0..<steps {
            serial += 1
            pick()(self)
            if step == 90 { harness.find("t1") }
            if step == 180 { harness.find("") }
            harness.push("random \(step)")
        }
    }
}

@MainActor
@Suite("ChatModel rebuild randomized")
struct ChatModelRebuildRandomTests {
    @Test("randomized snapshot sequences equal a full rebuild at every step", arguments: [1, 7, 42, 2026, 31337, 90210] as [UInt64])
    func randomizedSequences(seed: UInt64) throws {
        let script = try RebuildScript(seed: seed)
        script.run(steps: 260)
        #expect(script.harness.model.rebuilds.patched > 20)
    }
}
