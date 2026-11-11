import Foundation
import PalProtocol

struct StagedFiles: Sendable {
    var images: [StagedImage] = []
    var documentRefs: [String] = []

    func composedText(note: String) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = ([trimmed] + documentRefs).filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: "\n") }
        return images.map { $0.text ?? "[User attached image: \($0.name)]" }.joined(separator: "\n")
    }
}

extension SessionAPI {
    public func submit(
        sessionID: String,
        text: String,
        submissionID: String,
        attachments: [PromptAttachment] = [],
        files: [OutgoingFile],
        hidden: Bool = false,
        voiceTurn: Bool = false
    ) async throws -> AdmissionStatus {
        guard !files.isEmpty else {
            return try await submit(
                sessionID: sessionID,
                text: text,
                submissionID: submissionID,
                attachments: attachments,
                hidden: hidden,
                voiceTurn: voiceTurn
            )
        }
        let staged = try await stage(files, sessionID: sessionID)
        return try await submit(
            sessionID: sessionID,
            text: staged.composedText(note: text),
            submissionID: submissionID,
            attachments: attachments + staged.images.map(\.promptAttachment),
            hidden: hidden,
            voiceTurn: voiceTurn
        )
    }

    func stage(_ files: [OutgoingFile], sessionID: String) async throws -> StagedFiles {
        var staged = StagedFiles()
        for file in files {
            switch file.kind {
            case .image:
                staged.images.append(try await attachImage(sessionID: sessionID, data: file.data, filename: file.name))
            case .document:
                let document = try await attachFile(sessionID: sessionID, data: file.data, name: file.name, mime: file.mime)
                staged.documentRefs.append(document.refText)
            }
        }
        return staged
    }
}
