import Foundation
import PalChat

extension ChatModel {
    var suspendsTypeToFocus: Bool { isFinding }

    func noteDraft(_ text: String) {
        links.drafts.update(text: text, botID: bot.name)
    }

    func flushDraft() {
        links.drafts.flush()
    }

    func keepDraft(text: String, attachments: [PendingAttachment]) {
        roster.drafts[bot.name] = text
        for attachment in attachments where !pending.items.contains(where: { $0.id == attachment.id }) { pending.append(attachment) }
    }

    func rememberInDraft(_ attachment: PendingAttachment, data: Data, mime: String) {
        let store = links.drafts
        let botID = bot.name
        let kind: DraftAttachment.Kind = attachment.kind == .image ? .image : .file
        enqueueDraftWork {
            _ = try? store.addAttachment(
                botID: botID, id: attachment.id, kind: kind, name: attachment.name, mime: mime, data: data, thumbnail: attachment.thumbnail
            )
        }
    }

    func forgetInDraft(_ ids: [UUID]) {
        let store = links.drafts
        let botID = bot.name
        enqueueDraftWork { for id in ids { store.removeAttachment(id: id, botID: botID) } }
    }

    func restoreDraft() async {
        let store = links.drafts
        let botID = bot.name
        await draftWork?.value
        let restored = await Task.detached { () -> (ComposerDraft, [UUID: (data: Data?, thumbnail: Data?)]) in
            let draft = store.load(botID: botID)
            let files = Dictionary(uniqueKeysWithValues: draft.attachments.map {
                ($0.id, (store.attachmentData($0, botID: botID), store.thumbnailData($0, botID: botID)))
            })
            return (draft, files)
        }.value
        guard !Task.isCancelled else { return }
        if !restored.0.text.isEmpty, restoredDraft == nil { restoredDraft = restored.0.text }
        for item in restored.0.attachments where !pending.items.contains(where: { $0.id == item.id }) {
            let files = restored.1[item.id]
            guard let data = files?.data else {
                let reason = String(localized: "This attachment was removed.")
                pending.append(PendingAttachment(
                    id: item.id, kind: item.kind == .image ? .image : .file, name: item.name,
                    thumbnail: files?.thumbnail, state: .failed(reason: reason)
                ))
                continue
            }
            let upload = PreparedUpload(data: data, filename: item.name, thumbnail: files?.thumbnail)
            if item.kind == .image {
                attachPhoto(upload, id: item.id, remember: false)
            } else {
                attachFile(upload, mime: item.mime, id: item.id, remember: false)
            }
        }
    }

    func consumeRestoredDraft() -> String? {
        defer { restoredDraft = nil }
        return restoredDraft
    }

    static func imageMime(of filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: "image/jpeg"
        }
    }

    private func enqueueDraftWork(_ work: @escaping @Sendable () -> Void) {
        let previous = draftWork
        draftWork = Task.detached {
            await previous?.value
            work()
        }
    }
}
