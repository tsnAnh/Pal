import HermesBotProfile
import HermesChat
import HermesDesign
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct RoomView: View {
    @State private var model: RoomModel
    @State private var draft = ""
    @State private var dictation = DictationController()
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var showsDetails = false
    @State private var exported: RoomExportedFile?
    @FocusState private var composerFocused: Bool

    let roster: RosterModel
    let router: AppRouter

    @Environment(\.hermesTheme) private var theme

    init(model: RoomModel, roster: RosterModel, router: AppRouter) {
        _model = State(initialValue: model)
        self.roster = roster
        self.router = router
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.events) { event in
                    RoomEventRow(
                        event: event, room: model.room, roster: roster, canDownload: model.canDownload
                    ) { attachment, event in download(attachment, event) }
                    .id(event.seq)
                }
                ForEach(model.pendingActions) { action in
                    RoomActionCard(
                        action: action, room: model.room, isBusy: model.busyActions.contains(action.id),
                        approve: { model.approve(action, allow: $0) },
                        retry: { model.retry(action) },
                        discard: { model.discard(action) }
                    )
                    .padding(.top, 10)
                }
                workingLine
                if model.isUnreachable { ChatStatusLine(text: String(localized: "Reconnecting…"), dotColor: Color(theme.palette.chipSelectedFill)).padding(.top, 12) }
            }
            .padding(.horizontal, ChatMetrics.edgeMargin)
            .padding(.top, 8)
            .chatColumn()
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .bottom) { bottomBar.chatColumn() }
        #if os(macOS)
        .safeAreaBar(edge: .top) { header }
        .background(PalTokens.content)
        #else
        .background(Color(theme.palette.canvas))
        .toolbar {
            ToolbarItem(placement: .principal) { titleCapsule }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .trailingBar) { stopButton }
        }
        .toolbarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("roomScreen")
        .task { await model.run() }
        .onDisappear { dictation.stop() }
        .onChange(of: model.pendingDraft, initial: true) { _, pending in
            guard let pending else { return }
            draft = pending
            model.clearPendingDraft()
            composerFocused = true
        }
        .sheet(isPresented: $showsDetails) { RoomDetailsSheet(model: model, roster: roster) }
        .fileExporter(isPresented: exportBinding, document: exported?.document, contentType: .data, defaultFilename: exported?.name) { _ in
            exported = nil
        }
        .alert(
            Text("Something went wrong"),
            isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.dismissFailure() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
    }

    private var exportBinding: Binding<Bool> {
        Binding(get: { exported != nil }, set: { if !$0 { exported = nil } })
    }

    @ViewBuilder
    private var workingLine: some View {
        let names = model.room.members.filter { model.busyMemberIDs().contains($0.memberID) }.map(\.displayName)
        if !names.isEmpty {
            ChatWorkingRow(status: String(localized: "\(names.formatted(.list(type: .and))) working"), accent: nil)
                .padding(.top, 12)
        } else if model.isBusy {
            ChatWorkingRow(status: nil, accent: nil).padding(.top, 12)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            RoomMemberStrip(room: model.room, roster: roster, busy: model.busyMemberIDs()) { member in
                draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + "@\(member.handle) "
                composerFocused = true
            }
            .padding(.top, 6)
            ChatComposer(
                botName: model.room.name,
                accent: nil,
                attachments: model.pendingAttachments,
                slashItems: [],
                loadSlashItems: {},
                replyTarget: nil,
                cancelReply: {},
                canSend: model.canSend,
                dictation: dictation,
                draft: $draft,
                focused: $composerFocused,
                send: {
                    dictation.stop()
                    model.send(draft)
                    draft = ""
                },
                openVoiceMode: nil,
                removeAttachment: { model.removeUpload($0) },
                attachPhotos: { items in Task { await loadPhotos(items) } },
                attachCapture: { image in Task { await stage(image: image) } },
                attachImageData: { data in Task { await stage(imageData: data) } },
                attachFiles: { urls in Task { await loadFiles(urls) } }
            )
        }
    }

    private var stopButton: some View {
        Button { model.stop() } label: {
            Image(systemName: "stop.fill")
        }
        .disabled(!model.canStop)
        .opacity(model.canStop ? 1 : 0)
        .accessibilityLabel(Text("Stop"))
        .accessibilityIdentifier("roomStopButton")
    }

    private var titleCapsule: some View {
        Button { showsDetails = true } label: {
            HStack(spacing: 9) {
                Image(systemName: "person.2.fill").font(.system(size: 13))
                Text(model.room.name).hermesText(.botName).lineLimit(1)
            }
            .foregroundStyle(Color(theme.palette.textPrimary))
            .padding(.horizontal, 13)
            .frame(height: ChatMetrics.headerButtonDiameter)
            .glassEffect(.regular.tint(Color(theme.palette.glassCapsuleFill).opacity(0.55)), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(model.room.name))
        .accessibilityHint(Text("Shows details for this group chat"))
        .accessibilityIdentifier("roomTitle")
    }

    #if os(macOS)
    private var header: some View {
        GlassEffectContainer(spacing: 24) {
            ZStack {
                titleCapsule
                HStack {
                    Spacer()
                    stopButton.buttonStyle(.plain).foregroundStyle(PalTokens.textPrimary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: MacMetrics.topBarHeight)
        }
    }
    #endif

    private func download(_ attachment: RoomAttachment, _ event: RoomEvent) {
        Task {
            guard let data = await model.download(attachment, in: event) else { return }
            exported = RoomExportedFile(name: attachment.name, document: RoomFileDocument(data: data))
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                model.reportAttachmentFailure(String(localized: "That photo couldn't be loaded."))
                continue
            }
            await stage(imageData: data)
        }
    }

    private func stage(imageData data: Data) async {
        do {
            let upload = try await Task.detached { try AttachmentPreparer.prepareImage(from: data) }.value
            model.attach(upload, mime: "image/jpeg")
        } catch {
            model.reportAttachmentFailure(String(localized: "That photo couldn't be prepared."))
        }
    }

    private func stage(image: PlatformImage) async {
        do {
            let upload = try await Task.detached { try AttachmentPreparer.prepareImage(from: image) }.value
            model.attach(upload, mime: "image/jpeg")
        } catch {
            model.reportAttachmentFailure(String(localized: "That photo couldn't be prepared."))
        }
    }

    private func loadFiles(_ urls: [URL]) async {
        let items = DropIntake.classify(urls)
        if let message = DropIntake.rejectionMessage(for: items) { model.reportAttachmentFailure(message) }
        for item in items {
            let url: URL
            switch item {
            case .image(let accepted), .document(let accepted): url = accepted
            case .rejected: continue
            }
            do {
                let prepared = try await Task.detached { try AttachmentPreparer.prepareFile(at: url) }.value
                model.attach(prepared.upload, mime: prepared.mime)
            } catch AttachmentError.tooLarge {
                model.reportAttachmentFailure(String(localized: "That file is too large to send."))
            } catch {
                model.reportAttachmentFailure(String(localized: "That file couldn't be read."))
            }
        }
    }
}

struct RoomFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct RoomExportedFile {
    let name: String
    let document: RoomFileDocument
}
