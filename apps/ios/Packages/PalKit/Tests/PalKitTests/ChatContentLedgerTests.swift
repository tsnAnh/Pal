import PalChat
import Testing

@Suite("Chat content ledger")
struct ChatContentLedgerTests {
    private func geometry(content: Double, container: Double = 800, inset: Double = 0) -> ChatScrollGeometry {
        ChatScrollGeometry(
            offsetY: 0, contentHeight: content, containerHeight: container, containerWidth: 600, insetTop: inset, insetBottom: 0
        )
    }

    @Test func aSteadyContentHeightHasNoSource() {
        var ledger = ChatContentLedger()
        #expect(ledger.attribute(from: geometry(content: 4000), to: geometry(content: 4000.2)) == .none)
        #expect(ledger.attribute(from: nil, to: geometry(content: 4000)) == .none)
    }

    @Test func aRowsEventOwnsTheNextContentChange() {
        var ledger = ChatContentLedger()
        ledger.noteRows()
        #expect(ledger.attribute(from: geometry(content: 4000), to: geometry(content: 4100)) == .rows)
        #expect(ledger.attribute(from: geometry(content: 4100), to: geometry(content: 4150)) == .estimateReplaced)
    }

    @Test func aRowsEventExpiresWhenNothingChangesAfterIt() {
        var ledger = ChatContentLedger()
        ledger.noteRows()
        for _ in 0..<ChatContentLedger.rowsLifetime {
            _ = ledger.attribute(from: geometry(content: 4000), to: geometry(content: 4000))
        }
        #expect(ledger.attribute(from: geometry(content: 4000), to: geometry(content: 4040)) == .estimateReplaced)
    }

    @Test func aContentChangeWhileTheBotRunsIsStreamingGrowth() {
        var ledger = ChatContentLedger()
        ledger.noteStreaming(true)
        #expect(ledger.attribute(from: geometry(content: 4000), to: geometry(content: 4020)) == .streamingGrowth)
        ledger.noteStreaming(false)
        #expect(ledger.attribute(from: geometry(content: 4020), to: geometry(content: 4060)) == .estimateReplaced)
    }

    @Test func aChangedBoxIsAnInsetChangeBeforeAnythingElse() {
        var ledger = ChatContentLedger()
        ledger.noteRows()
        ledger.noteStreaming(true)
        #expect(ledger.attribute(from: geometry(content: 4000), to: geometry(content: 4030, container: 760)) == .inset)
        #expect(ledger.attribute(from: geometry(content: 4030), to: geometry(content: 4060, inset: 40)) == .inset)
    }
}
