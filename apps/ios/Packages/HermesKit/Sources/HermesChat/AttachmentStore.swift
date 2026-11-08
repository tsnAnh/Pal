import Foundation

struct AttachmentStore: Sendable {
    let root: URL

    init(directory: URL) {
        root = directory.appendingPathComponent("attachments", isDirectory: true)
    }

    func save(_ files: [OutgoingFile], submissionID: String) throws -> [PromptAttachment] {
        guard !files.isEmpty else { return [] }
        guard files.count <= OutgoingFile.maximumPerMessage else { throw AttachmentError.tooMany }
        let directory = root.appendingPathComponent(submissionID, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try files.enumerated().map { index, file in
                let stored = "\(submissionID)/\(index)-\(file.name)"
                try file.data.write(to: root.appendingPathComponent(stored), options: Self.writeOptions)
                return PromptAttachment(name: file.name, mime: file.mime, stored: stored)
            }
        } catch {
            remove(submissionID: submissionID)
            throw error
        }
    }

    func load(_ attachments: [PromptAttachment]) throws -> [OutgoingFile] {
        try attachments.map { attachment in
            let url = root.appendingPathComponent(attachment.stored).standardizedFileURL
            guard url.path.hasPrefix(root.standardizedFileURL.path + "/"),
                  let data = try? Data(contentsOf: url)
            else { throw AttachmentError.unreadable(name: attachment.name) }
            return try OutgoingFile(name: attachment.name, mime: attachment.mime, data: data)
        }
    }

    func remove(submissionID: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(submissionID, isDirectory: true))
    }

    func sweep(keeping submissionIDs: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where !submissionIDs.contains(name) { remove(submissionID: name) }
    }

    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }
}
