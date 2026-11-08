import HermesDesign
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatComposer: View {
    let botName: String
    let accent: BotAccent?
    let attachments: [PendingAttachment]
    let canSend: Bool
    let dictation: DictationController
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let send: () -> Void
    let openVoiceMode: () -> Void
    let removeAttachment: (UUID) -> Void
    let attachPhotos: ([PhotosPickerItem]) -> Void
    let attachCapture: (UIImage) -> Void
    let attachFiles: ([URL]) -> Void

    @Environment(\.hermesTheme) private var theme
    @State private var isPhotoPickerPresented = false
    @State private var isCameraPresented = false
    @State private var isFileImporterPresented = false
    @State private var pickedPhotos: [PhotosPickerItem] = []

    private var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var actionFill: Color { accent?.accent ?? Color(theme.palette.chipSelectedFill) }
    private var actionInk: Color { accent?.foreground ?? Color(theme.palette.chipSelectedText) }

    var body: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty { AttachmentTray(attachments: attachments, remove: removeAttachment) }
            HStack(alignment: .bottom, spacing: 6) {
                attachMenu
                field
                micButton
                trailingButton
            }
            .padding(ChatMetrics.composerInset)
            .frame(minHeight: ChatMetrics.composerHeight)
            .glassEffect(.regular.tint(Color(theme.palette.glassCapsuleFill).opacity(0.55)), in: .rect(cornerRadius: ChatMetrics.composerHeight / 2))
        }
        .padding(.horizontal, ChatMetrics.composerHorizontalMargin)
        .padding(.vertical, 8)
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $pickedPhotos, maxSelectionCount: 4, matching: .images)
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            attachPhotos(items)
            pickedPhotos = []
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPicker(onCapture: attachCapture).ignoresSafeArea()
        }
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attachFiles(urls) }
        }
    }

    private var attachMenu: some View {
        Menu {
            Button { isPhotoPickerPresented = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                .accessibilityIdentifier("attachPhotos")
            if CameraPicker.isAvailable {
                Button { isCameraPresented = true } label: { Label("Camera", systemImage: "camera") }
                    .accessibilityIdentifier("attachCamera")
            }
            Button { isFileImporterPresented = true } label: { Label("Files", systemImage: "folder") }
                .accessibilityIdentifier("attachFiles")
        } label: {
            circle(systemName: "plus", fill: Color(theme.palette.circleButtonFill), ink: Color(theme.palette.textPrimary), weight: .regular)
        }
        .accessibilityLabel(Text("Add attachment"))
        .accessibilityIdentifier("attachButton")
    }

    private var field: some View {
        TextField("", text: $draft, prompt: Text("Ask \(botName)").foregroundStyle(Color(theme.palette.textTertiary)), axis: .vertical)
            .hermesText(.composerField)
            .foregroundStyle(Color(theme.palette.textPrimary))
            .lineLimit(1...5)
            .focused(focused)
            .submitLabel(.send)
            .onSubmit { if hasContent, canSend { send() } }
            .padding(.horizontal, 6)
            .frame(minHeight: ChatMetrics.composerButtonDiameter)
            .accessibilityLabel(Text("Message \(botName)"))
            .accessibilityIdentifier("composerField")
    }

    private var micButton: some View {
        Button {
            dictation.toggle(currentText: draft) { draft = $0 }
        } label: {
            circle(
                systemName: dictation.isActive ? "mic.fill" : "mic",
                fill: dictation.isActive ? actionFill : Color(theme.palette.circleButtonFill),
                ink: dictation.isActive ? actionInk : Color(theme.palette.textSecondary),
                weight: .regular
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(dictation.isActive ? "Stop dictation" : "Dictate"))
        .accessibilityIdentifier("micButton")
    }

    @ViewBuilder
    private var trailingButton: some View {
        if hasContent {
            Button(action: send) {
                circle(systemName: "arrow.up", fill: actionFill, ink: actionInk, weight: .bold)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.4)
            .accessibilityLabel(Text("Send"))
            .accessibilityIdentifier("sendButton")
        } else {
            Button(action: openVoiceMode) {
                circle(systemName: "waveform", fill: actionFill, ink: actionInk, weight: .semibold)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Voice mode"))
            .accessibilityIdentifier("voiceModeButton")
        }
    }

    private func circle(systemName: String, fill: Color, ink: Color, weight: Font.Weight) -> some View {
        Image(systemName: systemName)
            .font(.system(size: ChatMetrics.composerButtonDiameter * 0.5, weight: weight))
            .foregroundStyle(ink)
            .frame(width: ChatMetrics.composerButtonDiameter, height: ChatMetrics.composerButtonDiameter)
            .background(fill, in: Circle())
            .contentShape(Circle())
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
        if let data = attachment.thumbnail, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
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
