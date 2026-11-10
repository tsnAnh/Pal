import HermesDesign
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatComposer: View {
    let botName: String
    let accent: BotAccent?
    let attachments: [PendingAttachment]
    let replyTarget: ReplyTarget?
    let cancelReply: () -> Void
    let canSend: Bool
    let dictation: DictationController
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let send: () -> Void
    let openVoiceMode: () -> Void
    let removeAttachment: (UUID) -> Void
    let attachPhotos: ([PhotosPickerItem]) -> Void
    let attachCapture: (PlatformImage) -> Void
    let attachImageData: ImageDataHandler
    let attachFiles: FilesHandler

    #if os(macOS)
    @Environment(MacShell.self) private var shell
    @State private var surfaceFrame = CGRect.zero
    #endif
    @State private var isPhotoPickerPresented = false
    @State private var isCameraPresented = false
    @State private var isFileImporterPresented = false
    @State private var pickedPhotos: [PhotosPickerItem] = []

    private var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var buttonDiameter: CGFloat {
        #if os(macOS)
        27
        #else
        ChatMetrics.composerButtonDiameter
        #endif
    }

    private var surfaceHeight: CGFloat {
        #if os(macOS)
        42
        #else
        ChatMetrics.composerHeight
        #endif
    }

    private var bottomMargin: CGFloat {
        #if os(macOS)
        14
        #else
        8
        #endif
    }

    private var promptText: Text { Text("Message \(botName)") }

    private var actionFill: Color { accent?.accent ?? Color(rgb: 0xD7D7D7) }
    private var actionInk: Color { accent?.foreground ?? Color(rgb: 0x161616) }

    var body: some View {
        VStack(spacing: 8) {
            if let replyTarget { ReplyBar(target: replyTarget, botName: botName, accent: accent, cancel: cancelReply) }
            if !attachments.isEmpty { AttachmentTray(attachments: attachments, remove: removeAttachment) }
            composerRow
        }
        .padding(.horizontal, ChatMetrics.edgeMargin)
        .padding(.top, 8)
        .padding(.bottom, bottomMargin)
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $pickedPhotos, maxSelectionCount: 4, matching: .images)
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            attachPhotos(items)
            pickedPhotos = []
        }
        .cameraCapture(isPresented: $isCameraPresented, onCapture: attachCapture)
        .attachmentIntake(files: attachFiles, imageData: attachImageData)
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attachFiles(urls) }
        }
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            attachMenu
            field
            micButton
            trailingButton
        }
        .padding(.leading, macOnly(6, else: ChatMetrics.composerInset))
        .padding(.trailing, macOnly(7, else: ChatMetrics.composerInset))
        .padding(.vertical, macOnly(7, else: ChatMetrics.composerInset))
        .frame(minHeight: surfaceHeight)
        .modifier(ComposerSurface(cornerRadius: surfaceHeight / 2, isFocused: focused.wrappedValue))
        #if os(macOS)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { surfaceFrame = $0 }
        #endif
    }

    private func macOnly(_ mac: CGFloat, else other: CGFloat) -> CGFloat {
        #if os(macOS)
        mac
        #else
        other
        #endif
    }

    @ViewBuilder
    private var attachMenu: some View {
        #if os(macOS)
        Button {
            shell.attachMenu = MacAttachMenuRequest(
                anchor: CGPoint(x: surfaceFrame.minX, y: surfaceFrame.minY - 6),
                items: [
                    MacPopupItem(title: String(localized: "Attach files"), symbol: "paperclip", identifier: "attachFiles") { isFileImporterPresented = true },
                    MacPopupItem(title: String(localized: "Photo Library"), symbol: "photo.on.rectangle", identifier: "attachPhotos") { isPhotoPickerPresented = true },
                ]
            )
        } label: {
            plainIcon("plus")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add attachment"))
        .accessibilityIdentifier("attachButton")
        #else
        Menu {
            Button { isFileImporterPresented = true } label: { Label("Attach files", systemImage: "paperclip") }
                .accessibilityIdentifier("attachFiles")
            Button { isPhotoPickerPresented = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                .accessibilityIdentifier("attachPhotos")
            if CameraCapture.isAvailable {
                Button { isCameraPresented = true } label: { Label("Camera", systemImage: "camera") }
                    .accessibilityIdentifier("attachCamera")
            }
        } label: {
            plainIcon("plus")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(Text("Add attachment"))
        .accessibilityIdentifier("attachButton")
        #endif
    }

    private var field: some View {
        TextField("", text: $draft, prompt: promptText.foregroundStyle(PalTokens.textTertiary), axis: .vertical)
            .hermesText(.composerField)
            .foregroundStyle(PalTokens.textPrimary)
            .lineLimit(1...5)
            .focused(focused)
            .submitLabel(.send)
            .onSubmit { if hasContent, canSend { send() } }
            #if os(macOS)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) {
                    draft += "\n"
                } else if hasContent, canSend {
                    send()
                }
                return .handled
            }
            #endif
            .padding(.horizontal, 6)
            .frame(minHeight: buttonDiameter)
            .accessibilityLabel(Text("Message \(botName)"))
            .accessibilityIdentifier("composerField")
    }

    @ViewBuilder
    private var micButton: some View {
        Button {
            dictation.toggle(currentText: draft) { draft = $0 }
        } label: {
            if dictation.isActive {
                actionCircle(systemName: "mic.fill", weight: .regular)
            } else {
                plainIcon("mic")
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(dictation.isActive ? "Stop dictation" : "Dictate"))
        .accessibilityIdentifier("micButton")
    }

    @ViewBuilder
    private var trailingButton: some View {
        if hasContent {
            Button(action: send) {
                actionCircle(systemName: "arrow.up", weight: .bold)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.4)
            .accessibilityLabel(Text("Send"))
            .accessibilityIdentifier("sendButton")
        } else {
            Button(action: openVoiceMode) {
                actionCircle(systemName: "waveform", weight: .semibold)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Voice mode"))
            .accessibilityIdentifier("voiceModeButton")
        }
    }

    private func plainIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: macOnly(14, else: 17), weight: .regular))
            .foregroundStyle(PalTokens.textSecondary)
            .frame(width: macOnly(28, else: buttonDiameter), height: buttonDiameter)
            .contentShape(Rectangle())
    }

    private func actionCircle(systemName: String, weight: Font.Weight) -> some View {
        Image(systemName: systemName)
            .font(.system(size: buttonDiameter * macOnly(0.48, else: 0.5), weight: weight))
            .foregroundStyle(actionInk)
            .frame(width: buttonDiameter, height: buttonDiameter)
            .background(actionFill, in: Circle())
            .contentShape(Circle())
    }
}

private struct ReplyBar: View {
    let target: ReplyTarget
    let botName: String
    let accent: BotAccent?
    let cancel: () -> Void

    @Environment(\.hermesTheme) private var theme

    private var title: Text {
        switch target.author {
        case .you: Text("Replying to yourself")
        case .bot: Text("Replying to \(botName)")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(accent?.accent ?? PalTokens.inverseFill)
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                title
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PalTokens.textPrimary)
                Text(target.quote)
                    .font(.system(size: 12))
                    .foregroundStyle(PalTokens.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PalTokens.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel reply"))
            .accessibilityIdentifier("replyCancel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(PalTokens.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(PalTokens.panelBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("replyBar")
    }
}

private struct ComposerSurface: ViewModifier {
    let cornerRadius: CGFloat
    let isFocused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(PalTokens.elevated, in: shape)
            .overlay(shape.strokeBorder(isFocused ? PalTokens.borderStrong : PalTokens.panelBorder, lineWidth: 1))
    }
}

private struct AttachmentTray: View {
    let attachments: [PendingAttachment]
    let remove: (UUID) -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    chip(attachment)
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityIdentifier("attachmentTray")
    }

    private func chip(_ attachment: PendingAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            content(attachment)
                .frame(width: 60, height: 60)
                .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { overlay(attachment) }
            Button { remove(attachment.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color(theme.palette.textPrimary), Color(theme.palette.circleButtonFill))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel(Text("Remove \(attachment.name)"))
            .accessibilityIdentifier("removeAttachment")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachmentChip")
    }

    @ViewBuilder
    private func content(_ attachment: PendingAttachment) -> some View {
        if let data = attachment.thumbnail, let image = PlatformImage(data: data) {
            Image(platformImage: image).resizable().scaledToFill()
        } else {
            VStack(spacing: 4) {
                Image(systemName: "doc").font(.system(size: 20))
                Text(attachment.name).font(.caption2).lineLimit(1).padding(.horizontal, 4)
            }
            .foregroundStyle(Color(theme.palette.textSecondary))
        }
    }

    @ViewBuilder
    private func overlay(_ attachment: PendingAttachment) -> some View {
        switch attachment.state {
        case .uploading:
            ZStack {
                Color.black.opacity(0.35)
                ProgressView().controlSize(.small)
            }
            .accessibilityIdentifier("attachmentUploading")
        case .failed:
            ZStack {
                Color.black.opacity(0.5)
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(theme.palette.destructive))
            }
        case .ready:
            EmptyView()
        }
    }
}
