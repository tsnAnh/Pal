extension ChatModel {
    static let attachmentNoticeDuration = Duration.seconds(4)

    func reportAttachmentFailureBriefly(_ message: String) {
        reportAttachmentFailure(message)
        Task { [weak self] in
            try? await Task.sleep(for: Self.attachmentNoticeDuration)
            guard let self, self.sendError == message else { return }
            self.dismissError()
        }
    }
}
