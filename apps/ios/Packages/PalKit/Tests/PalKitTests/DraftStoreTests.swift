import Foundation
import Testing

@testable import PalChat

struct DraftStoreTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-store-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func entries(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    @Test func draftsArePerBotAndSurviveRestart() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftStore(directory: directory)
        store.update(text: "hello A", botID: "a")
        let image = try store.addAttachment(
            botID: "a", id: UUID(), kind: .image, name: "pic.png", mime: "image/png",
            data: Data([1, 2, 3]), thumbnail: Data([9, 9])
        )
        let file = try store.addAttachment(
            botID: "a", id: UUID(), kind: .file, name: "doc.pdf", mime: "application/pdf",
            data: Data([4, 5]), thumbnail: nil
        )
        store.flush()

        let restored = DraftStore(directory: directory)
        let draft = restored.load(botID: "a")
        #expect(draft.text == "hello A")
        #expect(draft.attachments == [image, file])
        #expect(restored.attachmentData(image, botID: "a") == Data([1, 2, 3]))
        #expect(restored.thumbnailData(image, botID: "a") == Data([9, 9]))
        #expect(restored.attachmentData(file, botID: "a") == Data([4, 5]))
        #expect(restored.thumbnailData(file, botID: "a") == nil)
        #expect(restored.load(botID: "b") == .empty)
        #expect(await restored.loadDetached(botID: "a") == draft)
    }

    @Test func botIDsNeverShareOrEscapeADirectory() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent().appendingPathComponent("other")) }
        defer { try? FileManager.default.removeItem(at: directory) }
        let ids = ["../other", "a/b", "A", "a", ""]
        #expect(Set(ids.map(DraftStore.directoryName(for:))).count == ids.count)
        let store = DraftStore(directory: directory)
        for id in ids { store.update(text: "text \(id)", botID: id) }
        store.flush()
        #expect(entries(directory).count == ids.count)
        for id in ids { #expect(store.load(botID: id).text == "text \(id)") }
        #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("other").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("a").path))
    }

    @Test func clearRemovesOnlyThatBot() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftStore(directory: directory)
        for id in ["a", "b"] {
            store.update(text: "text \(id)", botID: id)
            _ = try store.addAttachment(
                botID: id, id: UUID(), kind: .file, name: "f.txt", mime: "text/plain", data: Data([1]), thumbnail: nil
            )
        }
        store.flush()
        store.clear(botID: "a")
        #expect(store.load(botID: "a") == .empty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(DraftStore.directoryName(for: "a")).path))
        #expect(store.load(botID: "b").text == "text b")
        #expect(store.load(botID: "b").attachments.count == 1)
    }

    @Test func debounceCoalescesWrites() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftStore(directory: directory, debounce: .milliseconds(150))
        for index in 0..<20 { store.update(text: "typing \(index)", botID: "a") }
        #expect(store.writeCount == 0)
        try await Task.sleep(for: .milliseconds(450))
        #expect(store.writeCount == 1)
        #expect(DraftStore(directory: directory).load(botID: "a").text == "typing 19")

        store.update(text: "final", botID: "a")
        store.flush()
        #expect(store.writeCount == 2)
        #expect(DraftStore(directory: directory).load(botID: "a").text == "final")
        try await Task.sleep(for: .milliseconds(350))
        #expect(store.writeCount == 2)
        store.flush()
        #expect(store.writeCount == 2)
    }

    @Test func missingAttachmentFileIsKeptButUnreadable() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftStore(directory: directory)
        let attachment = try store.addAttachment(
            botID: "a", id: UUID(), kind: .file, name: "gone.txt", mime: "text/plain", data: Data([1]), thumbnail: nil
        )
        let botDirectory = directory.appendingPathComponent(DraftStore.directoryName(for: "a"))
        try FileManager.default.removeItem(at: botDirectory.appendingPathComponent(attachment.stored))
        #expect(store.load(botID: "a").attachments == [attachment])
        #expect(store.attachmentData(attachment, botID: "a") == nil)
    }

    @Test func traversingStoredNameIsRejected() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([7]).write(to: directory.appendingPathComponent("secret"))
        let store = DraftStore(directory: directory)
        let forged = DraftAttachment(
            id: UUID(), kind: .file, name: "x", mime: "text/plain",
            stored: "../secret", thumbnail: "../secret"
        )
        #expect(store.attachmentData(forged, botID: "a") == nil)
        #expect(store.thumbnailData(forged, botID: "a") == nil)
    }

    @Test func emptyDraftDeletesItsDirectory() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftStore(directory: directory)
        store.update(text: "something", botID: "a")
        store.flush()
        let botDirectory = directory.appendingPathComponent(DraftStore.directoryName(for: "a"))
        #expect(FileManager.default.fileExists(atPath: botDirectory.path))
        store.update(text: "  \n ", botID: "a")
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: botDirectory.path))

        let attachment = try store.addAttachment(
            botID: "a", id: UUID(), kind: .file, name: "f.txt", mime: "text/plain", data: Data([1]), thumbnail: nil
        )
        store.removeAttachment(id: attachment.id, botID: "a")
        #expect(!FileManager.default.fileExists(atPath: botDirectory.path))
    }

    @Test func attachmentLimitsAreEnforced() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftStore(directory: directory)
        for index in 0..<10 {
            _ = try store.addAttachment(
                botID: "a", id: UUID(), kind: .file, name: "f\(index).txt", mime: "text/plain",
                data: Data([1]), thumbnail: nil
            )
        }
        #expect(throws: DraftError.tooMany) {
            try store.addAttachment(
                botID: "a", id: UUID(), kind: .file, name: "extra.txt", mime: "text/plain", data: Data([1]), thumbnail: nil
            )
        }
        #expect(throws: DraftError.tooLarge) {
            try store.addAttachment(
                botID: "b", id: UUID(), kind: .file, name: "big.bin", mime: "application/octet-stream",
                data: Data(count: 25 * 1024 * 1024 + 1), thumbnail: nil
            )
        }
        #expect(store.load(botID: "a").attachments.count == 10)
        #expect(store.load(botID: "b") == .empty)
    }

    @Test func corruptManifestLoadsEmpty() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let botDirectory = directory.appendingPathComponent(DraftStore.directoryName(for: "a"), isDirectory: true)
        try FileManager.default.createDirectory(at: botDirectory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: botDirectory.appendingPathComponent("draft.json"))
        #expect(DraftStore(directory: directory).load(botID: "a") == .empty)
    }
}
