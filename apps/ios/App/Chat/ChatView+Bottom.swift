import PalChat
import PalDesign
import SwiftUI

extension ChatView {
    var sink: AttachmentSink {
        AttachmentSink(
            photo: { model.attachPhoto($0) },
            file: { model.attachFile($0, mime: $1) },
            fail: { model.reportAttachmentFailureBriefly($0) }
        )
    }

    var attach: IntakeHandler {
        { batch in Task { await AttachmentStager.stage(batch, into: sink) } }
    }

    var attachActions: ComposerAttachActions {
        ComposerAttachActions(
            photos: { items in Task { await AttachmentStager.stage(photos: items, into: sink) } },
            capture: { image in Task { await AttachmentStager.stage(image: image, into: sink) } },
            intake: attach
        )
    }

    @ViewBuilder
    func bottomBar() -> some View {
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
        }
    }

    func reviewUsage() {
        #if os(macOS)
        shell.settingsSection = .usage
        router.present(.settings)
        #else
        router.presentSettings(route: .usage)
        #endif
    }

    var composer: some View {
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
            focused: $composerFocused,
            send: {
                dictation.stop()
                model.dismissError()
                model.send(draft)
                draft = ""
                scroll.jumpToBottom(animated: !reduceMotion)
            },
            openVoiceMode: {
                dictation.stop()
                composerFocused = false
                isVoiceModePresented = true
            },
            removeAttachment: { model.removeAttachment($0) },
            attachPhotos: { items in Task { await AttachmentStager.stage(photos: items, into: sink) } },
            attachCapture: { image in Task { await AttachmentStager.stage(image: image, into: sink) } },
            attach: attach
        )
    }

    var menu: some View {
        Menu {
            if router.supports(.viewProfile) {
                Button { router.perform(.viewProfile, botName: model.bot.name) } label: {
                    Label("View Profile", palIcon: "person.crop.circle")
                }
                .accessibilityIdentifier("chatMenuViewProfile")
            }
            Button {
                composerFocused = false
                model.beginFinding()
            } label: {
                Label("Find in Chat", palIcon: "magnifyingglass")
            }
            .accessibilityIdentifier("chatMenuFind")
            if router.supports(.shareAsTemplate) {
                Button { router.perform(.shareAsTemplate, botName: model.bot.name) } label: {
                    Label("Share as Template…", palIcon: "square.and.arrow.up")
                }
                .accessibilityIdentifier("chatMenuShareTemplate")
            }
        } label: {
            PalIcon("ellipsis")
                .accessibilityLabel(Text("Chat options"))
        }
        .tint(Color(theme.palette.textPrimary))
        .accessibilityIdentifier("chatMenuButton")
    }
}
