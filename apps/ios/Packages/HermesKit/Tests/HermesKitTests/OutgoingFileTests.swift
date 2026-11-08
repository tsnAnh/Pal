import CoreGraphics
import Foundation
import HermesChat
import HermesProtocol
import HermesTransport
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

private func imageData(_ type: UTType) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-files-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Outgoing files")
struct OutgoingFileTests {
    @Test func aPngKeepsItsTypeAndIsAnImage() throws {
        let file = try OutgoingFile(name: "shot.png", mime: "image/png", data: try imageData(.png))
        #expect(file.kind == .image)
        #expect(file.mime == "image/png")
        #expect(file.name == "shot.png")
    }

    @Test func aRasterTypeTheGatewayCannotAdmitBecomesAJpeg() throws {
        let file = try OutgoingFile(name: "scan.tiff", mime: "image/tiff", data: try imageData(.tiff))
        #expect(file.kind == .image)
        #expect(file.mime == "image/jpeg")
        #expect(file.name == "scan.jpg")
        #expect(file.data.starts(with: [0xFF, 0xD8, 0xFF]))
    }

    @Test func aPdfAndATextFileAreDocumentsKeptAsTheyAre() throws {
        let pdf = try OutgoingFile(name: "report.pdf", mime: "application/pdf", data: Data("%PDF-1.4".utf8))
        let note = try OutgoingFile(name: "todo.txt", mime: "text/plain", data: Data("buy milk".utf8))
        #expect(pdf.kind == .document)
        #expect(note.kind == .document)
        #expect(note.data == Data("buy milk".utf8))
    }

    @Test func anImageThatCannotBeDecodedIsSentAsADocument() throws {
        let file = try OutgoingFile(name: "logo.svg", mime: "image/svg+xml", data: Data("<svg/>".utf8))
        #expect(file.kind == .document)
    }

    @Test func pathsInANameAreStripped() throws {
        let file = try OutgoingFile(name: "../../etc/passwd.txt", mime: "text/plain", data: Data("x".utf8))
        #expect(file.name == "passwd.txt")
        let blank = try OutgoingFile(name: " ... ", mime: "text/plain", data: Data("x".utf8))
        #expect(blank.name == "attachment")
    }

    @Test func emptyOversizedAndUnsupportedFilesAreRefusedByName() throws {
        #expect(throws: AttachmentError.empty(name: "a.txt")) { _ = try OutgoingFile(name: "a.txt", mime: "text/plain", data: Data()) }
        let big = Data(count: OutgoingFile.maximumBytes + 1)
        #expect(throws: AttachmentError.tooLarge(name: "big.txt")) { _ = try OutgoingFile(name: "big.txt", mime: "text/plain", data: big) }
        #expect(throws: AttachmentError.unsupported(name: "clip.mov")) { _ = try OutgoingFile(name: "clip.mov", mime: "video/quicktime", data: Data("x".utf8)) }
        #expect(throws: AttachmentError.unsupported(name: "song.mp3")) { _ = try OutgoingFile(name: "song.mp3", mime: "audio/mpeg", data: Data("x".utf8)) }
        #expect(throws: AttachmentError.unsupported(name: "bundle.zip")) { _ = try OutgoingFile(name: "bundle.zip", mime: "application/zip", data: Data("x".utf8)) }
    }
}

@Suite("Outbox attachments", .serialized)
struct OutboxAttachmentTests {
    private final class Recorder: OutboxSubmitter {
        let seen = Mutex<[(OutboxEntry, [OutgoingFile])]>([])
        let failure: (@Sendable () -> (any Error)?)?

        init(failure: (@Sendable () -> (any Error)?)?) {
            self.failure = failure
        }

        func submit(_ entry: OutboxEntry, files: [OutgoingFile]) async throws -> AdmissionStatus {
            if let error = failure?() { throw error }
            seen.withLock { $0.append((entry, files)) }
            return try JSONValue.object(["admission_id": "a1", "status": "queued"]).decoded(as: AdmissionStatus.self)
        }
    }

    private func attachmentsDirectory(_ directory: URL) -> URL { directory.appendingPathComponent("attachments") }

    private func samples() throws -> [OutgoingFile] {
        [
            try OutgoingFile(name: "a.txt", mime: "text/plain", data: Data("alpha".utf8)),
            try OutgoingFile(name: "b.png", mime: "image/png", data: try imageData(.png)),
        ]
    }

    @Test func filesSurviveARestartAndReachTheSubmitterByteForByte() async throws {
        let directory = try temporaryDirectory()
        let first = try Outbox(directory: directory, submitter: Recorder(failure: nil))
        let entry = try await first.enqueue(botID: "bot", text: "look", files: try samples())
        #expect(entry.attachments.map(\.name) == ["a.txt", "b.png"])

        let recorder = Recorder(failure: nil)
        let restarted = try Outbox(directory: directory, submitter: recorder)
        let result = await restarted.deliver(entry.submissionID)
        guard case .admitted = result else {
            Issue.record("expected admitted, got \(result)")
            return
        }
        let delivered = try #require(recorder.seen.withLock { $0.first })
        #expect(delivered.1.map(\.name) == ["a.txt", "b.png"])
        #expect(delivered.1[0].data == Data("alpha".utf8))
        #expect(delivered.1[1].data == (try imageData(.png)))
    }

    @Test func admittedEntriesDropTheirFilesFromDisk() async throws {
        let directory = try temporaryDirectory()
        let outbox = try Outbox(directory: directory, submitter: Recorder(failure: nil))
        let entry = try await outbox.enqueue(botID: "bot", text: "x", files: try samples())
        #expect(FileManager.default.fileExists(atPath: attachmentsDirectory(directory).appendingPathComponent(entry.submissionID).path))
        _ = await outbox.deliver(entry.submissionID)
        #expect(!FileManager.default.fileExists(atPath: attachmentsDirectory(directory).appendingPathComponent(entry.submissionID).path))
    }

    @Test func aTransientFailureKeepsTheFilesForTheRetry() async throws {
        let directory = try temporaryDirectory()
        let outbox = try Outbox(directory: directory, submitter: Recorder(failure: { GatewayTransportError.timedOut }))
        let entry = try await outbox.enqueue(botID: "bot", text: "x", files: try samples())
        #expect(await outbox.deliver(entry.submissionID) == .retryLater)
        #expect(FileManager.default.fileExists(atPath: attachmentsDirectory(directory).appendingPathComponent(entry.submissionID).path))
    }

    @Test func aFailedEntryCanBeRequeuedWithItsFilesAndPurgingRemovesThem() async throws {
        let directory = try temporaryDirectory()
        let refusal = RPCError(code: 4001, message: "invalid_params", data: ["reason": "invalid_params"])
        let outbox = try Outbox(directory: directory, submitter: Recorder(failure: { GatewayTransportError.rpc(refusal) }))
        let entry = try await outbox.enqueue(botID: "bot", text: "x", files: try samples())
        #expect(await outbox.deliver(entry.submissionID) == .failed(reason: "invalid_params"))
        let failed = try #require(await outbox.snapshot(botID: "bot").first)
        let again = try await outbox.requeue(failed)
        #expect(again.submissionID != failed.submissionID)
        #expect(again.attachments.map(\.name) == ["a.txt", "b.png"])
        try await outbox.purgeFinished()
        #expect(!FileManager.default.fileExists(atPath: attachmentsDirectory(directory).appendingPathComponent(failed.submissionID).path))
        #expect(FileManager.default.fileExists(atPath: attachmentsDirectory(directory).appendingPathComponent(again.submissionID).path))
    }

    @Test func filesThatVanishedFailTheEntryInsteadOfSendingNothing() async throws {
        let directory = try temporaryDirectory()
        let outbox = try Outbox(directory: directory, submitter: Recorder(failure: nil))
        let entry = try await outbox.enqueue(botID: "bot", text: "x", files: try samples())
        try FileManager.default.removeItem(at: attachmentsDirectory(directory).appendingPathComponent(entry.submissionID))
        #expect(await outbox.deliver(entry.submissionID) == .failed(reason: Outbox.attachmentUnreadable))
    }

    @Test func cancellingRemovesTheFilesAndOrphansAreSweptAtStart() async throws {
        let directory = try temporaryDirectory()
        let outbox = try Outbox(directory: directory, submitter: Recorder(failure: nil))
        let entry = try await outbox.enqueue(botID: "bot", text: "x", files: try samples())
        try await outbox.cancel(entry.submissionID)
        #expect(!FileManager.default.fileExists(atPath: attachmentsDirectory(directory).appendingPathComponent(entry.submissionID).path))
        let orphan = attachmentsDirectory(directory).appendingPathComponent("orphan")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        _ = try Outbox(directory: directory, submitter: Recorder(failure: nil))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func moreFilesThanTheGatewayTakesAreRefusedBeforeAnythingIsStored() async throws {
        let directory = try temporaryDirectory()
        let outbox = try Outbox(directory: directory, submitter: Recorder(failure: nil))
        let many = try (0...OutgoingFile.maximumPerMessage).map { try OutgoingFile(name: "f\($0).txt", mime: "text/plain", data: Data("x".utf8)) }
        await #expect(throws: AttachmentError.tooMany) { _ = try await outbox.enqueue(botID: "bot", text: "x", files: many) }
        #expect(await outbox.snapshot().isEmpty)
    }
}
