import Foundation
import HermesProtocol

public struct StagedImage: Sendable, Equatable {
    public let path: String
    public let mime: String
    public let label: String
}

struct StagedFiles: Sendable {
    var images: [StagedImage] = []
    var documentRefs: [String] = []

    func composedText(note: String) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = ([trimmed] + documentRefs).filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: "\n") }
        return images.map(\.label).joined(separator: "\n")
    }
}

extension SessionAPI {
    public func submit(
        sessionID: String,
        text: String,
        submissionID: String,
        files: [OutgoingFile],
        hidden: Bool = false
    ) async throws -> AdmissionStatus {
        let staged = try await stage(files, sessionID: sessionID)
        return try await submit(
            sessionID: sessionID,
            text: staged.composedText(note: text),
            submissionID: submissionID,
            attachments: staged.images,
            hidden: hidden
        )
    }

    func stage(_ files: [OutgoingFile], sessionID: String) async throws -> StagedFiles {
        var staged = StagedFiles()
        for file in files {
            switch file.kind {
            case .image: staged.images.append(try await attachImage(file, sessionID: sessionID))
            case .document: staged.documentRefs.append(try await attachDocument(file, sessionID: sessionID))
            }
        }
        return staged
    }

    func attachImage(_ file: OutgoingFile, sessionID: String) async throws -> StagedImage {
        let result = try await call("image.attach_bytes", [
            "session_id": .string(sessionID),
            "content_base64": .string(file.data.base64EncodedString()),
            "filename": .string(file.name),
        ])
        guard let path = result["path"]?.stringValue, !path.isEmpty else { throw ChatError.unexpectedResponse(method: "image.attach_bytes") }
        return StagedImage(
            path: path,
            mime: result["mime"]?.stringValue ?? file.mime,
            label: result["text"]?.stringValue ?? "[User attached image: \(file.name)]"
        )
    }

    func attachDocument(_ file: OutgoingFile, sessionID: String) async throws -> String {
        let result = try await call("file.attach", [
            "session_id": .string(sessionID),
            "data_url": .string("data:\(file.mime);base64,\(file.data.base64EncodedString())"),
            "name": .string(file.name),
        ])
        guard let ref = result["ref_text"]?.stringValue, !ref.isEmpty else { throw ChatError.unexpectedResponse(method: "file.attach") }
        return ref
    }
}
