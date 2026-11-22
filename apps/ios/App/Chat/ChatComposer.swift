import PalChat
import PalDesign
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatComposer: View {
    let botName: String
    let accent: BotAccent?
    let answersQuestion: Bool
    let attachments: [PendingAttachment]
    let slashItems: [SlashItem]
    let loadSlashItems: () -> Void
    let fileRefResult: FileRefResult?
    let loadFileRefs: (String) -> Void
    let replyTarget: ReplyTarget?
    let cancelReply: () -> Void
    let canSend: Bool
    let dictation: DictationController
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let send: () -> Void
    let openVoiceMode: (() -> Void)?
    let removeAttachment: (UUID) -> Void
    let attachPhotos: ([PhotosPickerItem]) -> Void
    let attachCapture: (PlatformImage) -> Void
    let attach: IntakeHandler
    var prompt: String?
    var clearGlass = false

    #if os(macOS)
    @Environment(MacShell.self) private var shell
    #endif
    @State private var surfaceFrame = CGRect.zero
    @State private var isPhotoPickerPresented = false
    @State private var isCameraPresented = false
    @State private var isFileImporterPresented = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    /// The draft the user dismissed the picker on; it stays closed until the draft changes.
    @State private var dismissedDraft: String?
    @State private var fileRefIndex = 0

    private var slashMatches: [SlashItem] {
        guard let query = SlashCatalog.query(in: draft), dismissedDraft != draft else { return [] }
        return SlashCatalog.filter(slashItems, query: query)
    }

    private var fileRefTrigger: FileRefTrigger? {
        guard SlashCatalog.query(in: draft) == nil, dismissedDraft != draft else { return nil }
        return FileRefCatalog.trigger(in: draft)
    }

    private var fileRefMatches: [FileRefItem] {
        guard let trigger = fileRefTrigger else { return [] }
        return FileRefCatalog.visible(fileRefResult, for: trigger)
    }

    private var showsFileRefEmpty: Bool {
        guard let trigger = fileRefTrigger else { return false }
        return FileRefCatalog.isSettled(fileRefResult, for: trigger) && fileRefMatches.isEmpty
    }

    private var isFileRefOpen: Bool { !fileRefMatches.isEmpty || showsFileRefEmpty }

    private var selectedFileRef: FileRefItem? {
        fileRefMatches.indices.contains(fileRefIndex) ? fileRefMatches[fileRefIndex] : nil
    }

    private var slashRows: [CompletionRow] {
        var shownGroups: Set<SlashItem.Group> = []
        return slashMatches.map { item in
            CompletionRow(
                id: item.command,
                title: item.command,
                subtitle: item.description,
                header: shownGroups.insert(item.group).inserted ? item.group.title : nil
            )
        }
    }

    private var fileRefRows: [CompletionRow] {
        fileRefMatches.map { item in
            let path = item.value
            let subtitle = (item.kind == .file || item.kind == .folder) && path != item.display ? path : item.meta
            return CompletionRow(id: item.text, title: item.display, subtitle: subtitle, header: nil)
        }
    }

    private var isAttachmentSheetPresented: Bool { isPhotoPickerPresented || isCameraPresented || isFileImporterPresented }

    private var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var buttonDiameter: CGFloat {
        PlatformVariant.pick(mac: 27, iOS: ChatMetrics.composerButtonDiameter)
    }

    private var surfaceHeight: CGFloat {
        PlatformVariant.pick(mac: 42, iOS: ChatMetrics.composerHeight)
    }

    private var bottomMargin: CGFloat {
        PlatformVariant.pick(mac: 14, iOS: 8)
    }

    private var promptText: Text { prompt.map { Text($0) } ?? (answersQuestion ? Text("Or type your own answer") : Text("Message \(botName)")) }

    private var actionFill: Color { BubblePalette.ink(accent: accent) }
    private var actionInk: Color { BubblePalette.inkText(accent: accent) }

    var body: some View {
        VStack(spacing: 8) {
            if !slashMatches.isEmpty {
                CompletionList(
                    rows: slashRows,
                    emptyText: nil,
                    selection: nil,
                    listIdentifier: "slashPicker",
                    rowIdentifierPrefix: "slashItem-",
                    showsContainer: false,
                    pick: { id in if let item = slashMatches.first(where: { $0.id == id }) { pickSlash(item) } }
                )
            } else if isFileRefOpen {
                CompletionList(
                    rows: fileRefRows,
                    emptyText: "No matching files",
                    selection: selectedFileRef?.id,
                    listIdentifier: "fileRefPicker",
                    rowIdentifierPrefix: "fileRefItem-",
                    pick: { id in if let item = fileRefMatches.first(where: { $0.id == id }) { pickFileRef(item) } }
                )
            }
            if let replyTarget { ReplyBar(target: replyTarget, botName: botName, accent: accent, cancel: cancelReply) }
            if !attachments.isEmpty { AttachmentTray(attachments: attachments, remove: removeAttachment) }
            composerRow
        }
        .padding(.horizontal, ChatMetrics.edgeMargin)
        .padding(.top, 8)
        .padding(.bottom, bottomMargin)
        .reportsComposerDraft(draft)
        .onChange(of: draft) { _, text in
            if fileRefIndex != 0 { fileRefIndex = 0 }
            if SlashCatalog.query(in: text) != nil { loadSlashItems() } else if let trigger = FileRefCatalog.trigger(in: text) { loadFileRefs(trigger.word) }
        }
        .onChange(of: focused.wrappedValue) { _, isFocused in
            ComposerDragForwarding.update(isFocused: isFocused)
            if !isFocused, !isAttachmentSheetPresented { dismissedDraft = draft }
        }
        .onChange(of: isAttachmentSheetPresented) { _, presented in
            if !presented { dismissedDraft = nil }
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $pickedPhotos, maxSelectionCount: 4, matching: .images)
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            attachPhotos(items)
            pickedPhotos = []
        }
        .cameraCapture(isPresented: $isCameraPresented, onCapture: attachCapture)
        .attachmentPaste(intake: attach)
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attach(DropBatch(files: urls)) }
        }
    }

    private func pickSlash(_ item: SlashItem) {
        draft = SlashCatalog.insertion(for: item)
        dismissedDraft = nil
        focused.wrappedValue = true
    }

    private func pickFileRef(_ item: FileRefItem, descend: Bool = false) {
        guard let trigger = FileRefCatalog.trigger(in: draft) else { return }
        draft = FileRefCatalog.replacement(in: draft, trigger: trigger, item: item, descend: descend).draft
        dismissedDraft = nil
        focused.wrappedValue = true
    }

    private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
        let action = ComposerKeys.returnAction(
            modifiers: press.modifiers.composerModifiers,
            isComposing: isComposingText,
            platform: ComposerInput.platform,
            hasCompletionSelection: selectedFileRef != nil
        )
        switch action {
        case .send:
            if hasContent, canSend { send() }
            return .handled
        case .acceptCompletion:
            if let item = selectedFileRef { pickFileRef(item) }
            return .handled
        case .newline:
            return ComposerInput.insertNewline() ? .handled : .ignored
        case .ignore:
            return .ignored
        }
    }

    private var isComposingText: Bool { ComposerInput.isComposing }

    private func moveFileRefSelection(by step: Int) -> KeyPress.Result {
        guard !fileRefMatches.isEmpty, !isComposingText else { return .ignored }
        fileRefIndex = (fileRefIndex + step + fileRefMatches.count) % fileRefMatches.count
        return .handled
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            attachMenu
            field
            micButton
            trailingButton
        }
        .padding(.leading, PlatformVariant.pick(mac: 6, iOS: ChatMetrics.composerInset))
        .padding(.trailing, PlatformVariant.pick(mac: 7, iOS: ChatMetrics.composerInset))
        .padding(.vertical, PlatformVariant.pick(mac: 7, iOS: ChatMetrics.composerInset))
        .frame(minHeight: surfaceHeight)
        .modifier(ComposerSurface(cornerRadius: surfaceHeight / 2, clear: clearGlass))
        .macOnly { $0.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { surfaceFrame = $0 } }

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
            Button { isFileImporterPresented = true } label: {
                Label("Attach files", palIcon: "paperclip")
            }
                .accessibilityIdentifier("attachFiles")
            Button { isPhotoPickerPresented = true } label: { Label("Photo Library", palIcon: "photo.on.rectangle") }
                .accessibilityIdentifier("attachPhotos")
            if CameraCapture.isAvailable {
                Button { isCameraPresented = true } label: { Label("Camera", palIcon: "camera") }
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
            .macOnly { field in
                field
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .onKeyPress(.escape, phases: .down) { _ in
                        guard !slashMatches.isEmpty || isFileRefOpen, !isComposingText else { return .ignored }
                        dismissedDraft = draft
                        return .handled
                    }
                    .onKeyPress(.upArrow, phases: .down) { _ in moveFileRefSelection(by: -1) }
                    .onKeyPress(.downArrow, phases: .down) { _ in moveFileRefSelection(by: 1) }
                    .onKeyPress(.tab, phases: .down) { press in
                        guard let item = selectedFileRef, press.modifiers.isEmpty, !isComposingText else { return .ignored }
                        pickFileRef(item, descend: true)
                        return .handled
                    }
            }

            .onKeyPress(.return, phases: .down, action: handleReturn)
            .padding(.horizontal, 6)
            .frame(minHeight: buttonDiameter)
            .accessibilityLabel(prompt.map { Text($0) } ?? Text("Message \(botName)"))
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
        } else if let openVoiceMode {
            Button(action: openVoiceMode) {
                actionCircle(systemName: "waveform", weight: .semibold)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Voice mode"))
            .accessibilityIdentifier("voiceModeButton")
        }
    }

    private func plainIcon(_ systemName: String) -> some View {
        PalIcon(systemName, ink: .secondary)
            .font(.system(size: PlatformVariant.pick(mac: 14, iOS: 17), weight: .regular))
            .frame(width: PlatformVariant.pick(mac: 28, iOS: buttonDiameter), height: buttonDiameter)
            .minimumHitTarget(visual: buttonDiameter)
    }

    private func actionCircle(systemName: String, weight: Font.Weight) -> some View {
        PalIcon(systemName, ink: .custom(actionInk))
            .font(.system(size: buttonDiameter * PlatformVariant.pick(mac: 0.48, iOS: 0.5), weight: weight))
            .frame(width: buttonDiameter, height: buttonDiameter)
            .background(actionFill, in: Circle())
            .minimumHitTarget(visual: buttonDiameter)
    }
}

private struct ComposerSurface: ViewModifier {
    let cornerRadius: CGFloat
    let clear: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        GlassEffectContainer {
            if clear {
                content.palClearGlass(shape, interactive: false)
            } else {
                content.palGlass(shape, interactive: false)
            }
        }
    }
}
