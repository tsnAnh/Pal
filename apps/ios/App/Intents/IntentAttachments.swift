import AppIntents
import Foundation
import PalChat

enum IntentAttachments {
    static func files(from intentFiles: [IntentFile]) throws -> [OutgoingFile] {
        guard intentFiles.count <= OutgoingFile.maximumPerMessage else { throw BotIntentError.tooManyFiles }
        return try intentFiles.map(file(from:))
    }

    private static func file(from intentFile: IntentFile) throws -> OutgoingFile {
        let name = intentFile.filename
        if let url = intentFile.fileURL,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > OutgoingFile.maximumBytes * 2 {
            throw BotIntentError.fileTooLarge(name: name)
        }
        let mime = intentFile.type?.preferredMIMEType ?? "application/octet-stream"
        do {
            return try OutgoingFile(name: name, mime: mime, data: intentFile.data)
        } catch {
            throw BotIntentError(error)
        }
    }
}
