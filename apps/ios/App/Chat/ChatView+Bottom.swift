import PalChat
import PalDesign
import PalDiagnostics
import SwiftUI

extension ChatModel {
    var attachmentSink: AttachmentSink {
        AttachmentSink(
            photo: { self.attachPhoto($0) },
            file: { self.attachFile($0, mime: $1) },
            fail: { self.reportAttachmentFailureBriefly($0) }
        )
    }

    var attachIntake: IntakeHandler {
        let sink = attachmentSink
        return { batch in Task { await AttachmentStager.stage(batch, into: sink) } }
    }

    var attachActions: ComposerAttachActions {
        let sink = attachmentSink
        return ComposerAttachActions(
            photos: { items in Task { await AttachmentStager.stage(photos: items, into: sink) } },
            capture: { image in Task { await AttachmentStager.stage(image: image, into: sink) } },
            intake: attachIntake
        )
    }
}

struct ChatBottomBar: View {
    let model: ChatModel
    let router: AppRouter
    let scroll: ChatScrollController
    let dictation: DictationController
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    @Binding var isVoiceModePresented: Bool

    @Environment(SettingsHub.self) private var hub
    @Environment(\.heldDrafts) private var heldDrafts
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @Environment(MacShell.self) private var shell
    #endif

    var body: some View {
        let _ = PalPerf.event("chat.bottom.body") // swiftlint:disable:this redundant_discardable_let
        content
            .onChange(of: model.pendingDraft, initial: true) { _, pending in
                guard let pending else { return }
                draft = pending
                model.clearPendingDraft()
                focused.wrappedValue = true
            }
            .onChange(of: model.restoredDraft, initial: true) { _, restored in
                guard restored != nil, let text = model.consumeRestoredDraft(), draft.isEmpty else { return }
                draft = text
            }
            .onChange(of: model.replyTarget) { _, target in
                if target != nil { focused.wrappedValue = true }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.isFinding {
            FindBar(model: model)
        } else {
            VStack(spacing: 0) {
                if let notice = dictation.failure ?? model.sendError {
                    ComposerNotice(text: notice) {
                        dictation.dismissFailure()
                        model.dismissError()
                    }
                    .padding(.horizontal, ChatMetrics.edgeMargin)
                    .transition(.opacity)
                }
                let waiting = heldDrafts?.count(for: model.bot.name) ?? 0
                if waiting > 0, !model.isAskingClarify {
                    HeldDraftBanner(count: waiting) { router.presentApprovals(profile: model.bot.name) }
                        .padding(.horizontal, ChatMetrics.edgeMargin)
                        .transition(.opacity)
                }
                if let notice = hub.usageNotice {
                    UsageBanner(notice: notice) {
                        reviewUsage()
                    } dismiss: {
                        hub.dismissUsageNotice()
                    }
                    .padding(.horizontal, ChatMetrics.edgeMargin)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                composer
            }
            .animation(.snappy(duration: 0.2), value: hub.usageNotice)
            .animation(.easeOut(duration: 0.2), value: dictation.failure ?? model.sendError)
            .task { await hub.refreshUsageIfStale() }
            .task(id: model.bot.name) {
                await heldDrafts?.load(bots: [HeldDraftBot(name: model.bot.name, displayName: model.bot.displayName)])
            }
        }
    }

    private func reviewUsage() {
        #if os(macOS)
        shell.settingsSection = .usage
        router.present(.settings)
        #else
        router.presentSettings(route: .usage)
        #endif
    }

    private var composer: some View {
        ChatComposer(
            botName: model.bot.displayName,
            accent: model.chatAccent,
            answersQuestion: model.hasPendingClarify,
            attachments: model.attachments,
            slashItems: model.slashItems,
            loadSlashItems: { model.loadSlashItems() },
            fileRefResult: model.fileRefResult,
            loadFileRefs: { model.loadFileRefs(word: $0) },
            replyTarget: model.replyTarget,
            cancelReply: { model.cancelReply() },
            canSend: model.canSendAttachments,
            dictation: dictation,
            draft: $draft,
            focused: focused,
            send: { text in
                dictation.stop()
                var settled = Transaction()
                settled.disablesAnimations = true
                withTransaction(settled) {
                    model.dismissError()
                    model.send(text)
                    draft = ""
                }
                scroll.sent(animated: !reduceMotion)
            },
            openVoiceMode: {
                dictation.stop()
                focused.wrappedValue = false
                isVoiceModePresented = true
            },
            removeAttachment: { model.removeAttachment($0) },
            attachPhotos: { items in Task { await AttachmentStager.stage(photos: items, into: model.attachmentSink) } },
            attachCapture: { image in Task { await AttachmentStager.stage(image: image, into: model.attachmentSink) } },
            attach: model.attachIntake
        )
        .onChange(of: draft) { _, text in model.noteDraft(text) }
    }
}
