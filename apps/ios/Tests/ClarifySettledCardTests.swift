import PalChat
import PalDesign
import PalProtocol
import SwiftUI
import Testing

@testable import Pal

@MainActor
@Suite("Settled clarify card geometry")
struct ClarifySettledCardTests {
    private static let width: CGFloat = 340

    private func size<V: View>(_ view: V) -> CGSize {
        let sized = view.frame(width: Self.width)
        #if os(macOS)
        let host = NSHostingView(rootView: sized)
        return host.fittingSize
        #else
        let host = UIHostingController(rootView: sized)
        return host.sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude))
        #endif
    }

    private func settled(_ entries: ClarifySettled.Entry...) -> ClarifySettled { ClarifySettled(entries: entries) }

    private let single = ClarifySettled.Entry(question: "Which platform first?", chosen: ["Mac"])
    private let prompt = PendingPrompt(
        kind: .clarify, promptID: "srq-1", executionGeneration: 1,
        choices: ["Mac", "iPhone", "iPad"], question: "Which platform first?"
    )

    @Test("a settled single question is smaller than the live card and keeps its width")
    func smallerThanLive() {
        let live = size(ClarifyCard(prompt: prompt) { _, _ in true })
        let compact = size(ClarifySettledCard(settled: settled(single)))
        #expect(compact.width == live.width)
        #expect(compact.height > 0 && compact.height < live.height)
    }

    @Test("each chosen row of a multi-select adds one row")
    func multiSelectRows() {
        let one = size(ClarifySettledCard(settled: settled(.init(question: "Which?", chosen: ["A"]))))
        let three = size(ClarifySettledCard(settled: settled(.init(question: "Which?", chosen: ["A", "B", "C"]))))
        #expect(three.height > one.height)
        #expect(three.height - one.height > 2 * ClarifySettledMetrics.rowSpacing + 30)
    }

    @Test("a skipped question and a typed answer are one row each, like a pick")
    func skippedAndTyped() {
        let pick = size(ClarifySettledCard(settled: settled(single)))
        let skipped = size(ClarifySettledCard(settled: settled(.init(question: "Which platform first?", chosen: []))))
        let typed = size(ClarifySettledCard(settled: settled(.init(question: "Which platform first?", chosen: ["Watch"]))))
        #expect(abs(skipped.height - pick.height) < 8)
        #expect(typed.height == pick.height)
    }

    @Test("a collapsed form is one block, taller than one question and shorter than the live pages")
    func formBlock() {
        let questions = [
            ClarifyQuestion(qid: "q0", question: "Platforms?", choices: ["Mac", "iPhone", "iPad"]),
            ClarifyQuestion(qid: "q1", question: "Mockups first?", choices: ["Setup", "Connect Apps"], multiSelect: true),
        ]
        let form = PendingPrompt(kind: .clarify, promptID: "srq-2", executionGeneration: 1, questions: questions)
        let live = size(ClarifyFormCard(prompt: form) { _, _ in })
        let block = size(ClarifySettledCard(settled: settled(
            .init(question: "Platforms?", chosen: ["Mac"]), .init(question: "Mockups first?", chosen: ["Setup", "Connect Apps"])
        )))
        #expect(block.height > size(ClarifySettledCard(settled: settled(single))).height)
        #expect(block.height < live.height)
    }

    @Test("a long answer wraps instead of truncating")
    func wraps() {
        let long = String(repeating: "a very long answer ", count: 12)
        let wrapped = size(ClarifySettledCard(settled: settled(.init(question: "Why?", chosen: [long]))))
        let short = size(ClarifySettledCard(settled: settled(.init(question: "Why?", chosen: ["no"]))))
        #expect(wrapped.height > short.height * 1.5)
    }

    @Test("the outbound send card settles to its title and the chosen option")
    func outboundCard() {
        let sent = ClarifySettled(question: "Send this message?", option: .send)
        let titled = settled(.init(question: "Send this message?", chosen: ["Send"]))
        #expect(size(ClarifySettledCard(settled: sent)).height == size(ClarifySettledCard(settled: titled)).height)
    }

    @Test("the spoken label is the question and the answer, one element per block")
    func spoken() {
        #expect(ClarifySettledCard.spoken(settled(single)) == "Which platform first?: Mac")
        #expect(ClarifySettledCard.spoken(settled(single, .init(question: "More?", chosen: ["a", "b"]))) == "Which platform first?: Mac. More?: a, b")
        #expect(ClarifySettledCard.spoken(settled(.init(question: "Q?", chosen: []))) == "Q?: Skipped")
    }
}
