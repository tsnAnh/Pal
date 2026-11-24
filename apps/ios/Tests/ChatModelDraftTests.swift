import Foundation
import Testing

@testable import Pal
@testable import PalChat

@MainActor
@Suite("Per bot composer drafts", .serialized)
struct ChatModelDraftTests {
    private func store(_ directory: URL, debounce: Duration = .milliseconds(60)) -> DraftStore {
        DraftStore(directory: directory, debounce: debounce)
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "chat-drafts-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func model(_ bot: String, _ store: DraftStore) throws -> ChatModel {
        try rebuildChatModel(drafts: store, botName: bot)
    }

    private func photo(_ name: String) -> PreparedUpload {
        PreparedUpload(data: Data(name.utf8) + Data(repeating: 7, count: 64), filename: "\(name).png", thumbnail: Data(name.utf8))
    }

    @Test("a bot keeps its text and its two attachments, another bot starts empty, and both survive a restart")
    func perBotAndRestart() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = store(root)
        let alpha = try model("alpha", first)
        alpha.noteDraft("remember this")
        alpha.attachPhoto(photo("one"))
        alpha.attachFile(PreparedUpload(data: Data("notes".utf8), filename: "notes.txt", thumbnail: nil), mime: "text/plain")
        let ids = alpha.attachments.map(\.id)
        #expect(ids.count == 2)
        alpha.stop()
        await alpha.draftWork?.value

        let beta = try model("beta", first)
        await beta.restoreDraft()
        #expect(beta.restoredDraft == nil)
        #expect(beta.attachments.isEmpty)

        for reopened in [try model("alpha", first), try model("alpha", store(root))] {
            await reopened.restoreDraft()
            #expect(reopened.restoredDraft == "remember this")
            #expect(reopened.attachments.map(\.id) == ids)
            #expect(reopened.attachments.map(\.kind) == [.image, .file])
        }
    }

    @Test("typing writes nothing per keystroke, one write after the pause, and leaving flushes at once")
    func debounceAndFlush() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = store(root, debounce: .milliseconds(120))
        let chat = try model("alpha", drafts)
        for index in 0..<30 { chat.noteDraft(String(repeating: "x", count: index + 1)) }
        #expect(drafts.writeCount == 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(drafts.writeCount == 1)
        chat.noteDraft("one more")
        #expect(drafts.writeCount == 1)
        chat.stop()
        #expect(drafts.writeCount == 2)
        #expect(drafts.load(botID: "alpha").text == "one more")
    }

    @Test("a send that is saved takes its attachments out of the draft")
    func sendClears() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = store(root)
        let chat = try model("alpha", drafts)
        chat.attachPhoto(photo("one"))
        await chat.draftWork?.value
        #expect(drafts.load(botID: "alpha").attachments.count == 1)
        chat.forgetInDraft(chat.attachments.map(\.id))
        await chat.draftWork?.value
        #expect(drafts.load(botID: "alpha").attachments.isEmpty)
    }

    @Test("a send that failed puts the text and the attachments back and keeps their files")
    func failedSendKeepsTheDraft() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = store(root)
        let chat = try model("alpha", drafts)
        chat.attachPhoto(photo("one"))
        await chat.draftWork?.value
        let sent = chat.attachments
        chat.pending.remove(sent[0].id)
        #expect(chat.attachments.isEmpty)
        chat.keepDraft(text: "words", attachments: sent)
        #expect(chat.pendingDraft == "words")
        #expect(chat.attachments.map(\.id) == sent.map(\.id))
        #expect(drafts.load(botID: "alpha").attachments.count == 1)
    }

    @Test("an attachment whose file is gone comes back as a removed chip and nothing crashes")
    func missingFileShowsRemovedChip() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = store(root)
        let chat = try model("alpha", drafts)
        chat.attachPhoto(photo("one"))
        await chat.draftWork?.value
        let draft = drafts.load(botID: "alpha")
        let folder = root.appending(path: DraftStore.directoryName(for: "alpha"), directoryHint: .isDirectory)
        try FileManager.default.removeItem(at: folder.appending(path: draft.attachments[0].stored))
        let reopened = try model("alpha", store(root))
        await reopened.restoreDraft()
        #expect(reopened.attachments.count == 1)
        #expect(reopened.attachments[0].failureReason == String(localized: "This attachment was removed."))
    }
}
