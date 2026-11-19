import Foundation
import PalChat

extension ChatModel {
    func closeImageViewer() {
        if let staging = imageViewer?.staging {
            Task { if let id = await staging.task.value { removeAttachment(id) } }
        }
        imageViewer = nil
    }

    func removeViewerAttachment(_ id: UUID) {
        removeAttachment(id)
        if imageViewer?.staging?.attachmentID == id { imageViewer?.clearStaging() }
    }

    func stageViewerImage(_ image: ConversationImage) -> Task<UUID?, Never> {
        if let staging = imageViewer?.staging, staging.imageID == image.id { return staging.task }
        let task = Task { () -> UUID? in
            let id = await stageImage(image)
            if let id { imageViewer?.recordStaged(id, for: image.id) }
            return id
        }
        imageViewer?.beginStaging(ViewerStaging(imageID: image.id, task: task))
        return task
    }

    func sendFromViewer(_ composer: ViewerComposerState) {
        guard let state = imageViewer, let sent = ImageViewerSend.submit(state, composer: composer) else { return }
        let staging = state.staging?.imageID == sent.submission.image.id ? state.staging?.task : nil
        imageViewer = sent.viewer
        Task {
            var id = await staging?.value
            if id == nil || !attachments.contains(where: { $0.id == id }) { id = await stageImage(sent.submission.image) }
            guard let id, await waitUntilStaged(id) else {
                sendError = String(localized: "The image couldn't be attached, so your message wasn't sent.")
                return
            }
            send(sent.submission.text)
        }
    }

    private func stageImage(_ image: ConversationImage) async -> UUID? {
        do {
            let data = try await loadImage(image.reference, thumbnail: false)
            let name = (image.reference.name as NSString).deletingPathExtension
            let upload = try await Task.detached(priority: .userInitiated) {
                try AttachmentPreparer.prepareImage(from: data, name: name)
            }.value
            let known = Set(attachments.map(\.id))
            attachPhoto(upload)
            return attachments.first { !known.contains($0.id) }?.id
        } catch {
            reportAttachmentFailure(String(localized: "That image couldn't be attached."))
            return nil
        }
    }

    private func waitUntilStaged(_ id: UUID) async -> Bool {
        for _ in 0..<Self.stagingPolls {
            switch attachments.first(where: { $0.id == id })?.state {
            case .ready: return true
            case .uploading: try? await Task.sleep(for: Self.stagingPoll)
            case .failed, nil: return false
            }
        }
        return false
    }

    private static let stagingPoll = Duration.milliseconds(80)
    private static let stagingPolls = 750
}
