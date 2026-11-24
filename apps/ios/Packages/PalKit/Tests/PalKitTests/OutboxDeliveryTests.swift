import Foundation
@testable import PalChat
import PalProtocol
import PalTransport
import Synchronization
import Testing

private final class FlakySubmitter: OutboxSubmitter {
    private let failures: Mutex<Int>
    private let seen = Mutex<[String]>([])

    init(failures: Int) { self.failures = Mutex(failures) }

    var submissionIDs: [String] { seen.withLock { $0 } }

    func submit(_ entry: OutboxEntry, files: [OutgoingFile]) async throws -> AdmissionStatus {
        seen.withLock { $0.append(entry.submissionID) }
        let fails = failures.withLock { remaining -> Bool in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        if fails { throw GatewayTransportError.timedOut }
        return try JSONValue.object(["admission_id": "a", "status": "queued"]).decoded(as: AdmissionStatus.self)
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-delivery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Outbox delivery")
struct OutboxDeliveryTests {
    @Test func aGatewayThatNeverAnswersFailsTheEntryAfterBoundedAttempts() async throws {
        let outbox = try Outbox(directory: try temporaryDirectory(), submitter: FlakySubmitter(failures: .max))
        let entry = try await outbox.enqueue(botID: "b", text: "t")
        for _ in 1..<Outbox.maxDeliveryAttempts {
            #expect(await outbox.deliver(entry.submissionID) == .retryLater)
        }
        #expect(await outbox.deliver(entry.submissionID) == .failed(reason: Outbox.deliveryExhausted))
        #expect(await outbox.pending().isEmpty)
        let failed = try #require(await outbox.snapshot(botID: "b").first)
        #expect(failed.state == .failed(reason: Outbox.deliveryExhausted))
    }

    @Test func retryingAnExhaustedEntryReusesItsSubmissionIDAndDeliversOnce() async throws {
        let submitter = FlakySubmitter(failures: Outbox.maxDeliveryAttempts)
        let outbox = try Outbox(directory: try temporaryDirectory(), submitter: submitter)
        let entry = try await outbox.enqueue(botID: "b", text: "t")
        for _ in 1..<Outbox.maxDeliveryAttempts { _ = await outbox.deliver(entry.submissionID) }
        #expect(await outbox.deliver(entry.submissionID) == .failed(reason: Outbox.deliveryExhausted))
        let failed = try #require(await outbox.snapshot(botID: "b").first)
        let again = try await outbox.requeue(failed)
        #expect(again.submissionID == entry.submissionID)
        #expect(again.state == .pending)
        #expect(again.attempts == 0)
        guard case .admitted = await outbox.deliver(again.submissionID) else {
            Issue.record("the retry was not admitted")
            return
        }
        #expect(Set(submitter.submissionIDs) == [entry.submissionID])
        #expect(await outbox.snapshot(botID: "b").count == 1)
    }

    @Test func aQueuedReceiptAdmitsTheEntryAtOnceSoNoBubbleStaysSending() async throws {
        let outbox = try Outbox(directory: try temporaryDirectory(), submitter: FlakySubmitter(failures: 0))
        let entry = try await outbox.enqueue(botID: "b", text: "t")
        #expect(try #require(await outbox.snapshot(botID: "b").first).state.isAdmitted == false)
        guard case .admitted(let receipt) = await outbox.deliver(entry.submissionID) else {
            Issue.record("the queued receipt was not admitted")
            return
        }
        #expect(receipt.status == .queued)
        #expect(try #require(await outbox.snapshot(botID: "b").first).state.isAdmitted)
    }

    @Test func aReceiptMarksTheEntryAdmittedWithoutWaitingForAnyReply() async throws {
        let outbox = try Outbox(directory: try temporaryDirectory(), submitter: FlakySubmitter(failures: 0))
        let entry = try await outbox.enqueue(botID: "b", text: "t")
        guard case .admitted(let receipt) = await outbox.deliver(entry.submissionID) else {
            Issue.record("the receipt did not admit the entry")
            return
        }
        #expect(receipt.status == .queued)
        #expect(await outbox.snapshot(botID: "b").first?.state == .admitted(admissionID: "a"))
    }
}
