import Foundation
import PalChat
import Testing

@testable import Pal

@Suite("A message reads as sent once the gateway has its receipt")
struct BubbleDeliveryStateTests {
    private func entry(_ state: OutboxEntry.State) -> OutboxEntry {
        OutboxEntry(submissionID: "s1", botID: "b", text: "hi", attachments: [], createdAt: Date(), state: state, attempts: 0)
    }

    @Test func aMessageWithoutAReceiptIsPendingOnline() {
        #expect(BubbleDelivery.awaitingReceipt(offline: false, outbox: entry(.pending)) == .sending)
        #expect(BubbleDelivery.awaitingReceipt(offline: false, outbox: nil) == .sending)
    }

    @Test func aMessageWithoutAReceiptWaitsForTheConnectionOffline() {
        #expect(BubbleDelivery.awaitingReceipt(offline: true, outbox: entry(.pending)) == .waitingForConnection)
    }

    @Test(arguments: [true, false])
    func anAdmittedMessageIsSentWhetherOrNotTheStreamHasEchoedIt(offline: Bool) {
        #expect(BubbleDelivery.awaitingReceipt(offline: offline, outbox: entry(.admitted(admissionID: "a1"))) == .sent)
    }

    @Test func aFailedEntryIsNotCountedAsAdmitted() {
        #expect(BubbleDelivery.awaitingReceipt(offline: false, outbox: entry(.failed(reason: "refused"))) == .sending)
    }
}
