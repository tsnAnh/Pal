import Foundation
import PalChat
import Testing

@testable import Pal

@Suite("A message reads as sent once the gateway has its receipt")
struct BubbleDeliveryStateTests {
    private func entry(_ state: OutboxEntry.State) -> OutboxEntry {
        OutboxEntry(submissionID: "s1", botID: "b", text: "hi", attachments: [], createdAt: Date(), state: state, attempts: 0)
    }

    @Test func aMessageWithoutAReceiptIsPending() {
        #expect(BubbleDelivery.awaitingReceipt(outbox: entry(.pending)) == .sending)
        #expect(BubbleDelivery.awaitingReceipt(outbox: nil) == .sending)
    }

    @Test func anAdmittedMessageIsSentBeforeTheStreamHasEchoedIt() {
        #expect(BubbleDelivery.awaitingReceipt(outbox: entry(.admitted(admissionID: "a1"))) == .sent)
    }

    @Test func aFailedEntryIsNotCountedAsAdmitted() {
        #expect(BubbleDelivery.awaitingReceipt(outbox: entry(.failed(reason: "refused"))) == .sending)
    }
}
