import PalBotProfile
import PalDesign
import PalProtocol
import SwiftUI

struct ChatInstallView<Advanced: View>: View {
    @State private var model: ChatInstallModel
    @State private var access: String?
    @State private var refresh: String?
    @State private var appKey: String?
    @State private var avatarSaved = false
    @State private var confirmsDisconnect = false
    @State private var search = ""
    @State private var copied: String?

    let displayName: String
    let spec: BotAvatarSpec?
    let events: @Sendable () -> AsyncStream<ChatInstallChangedPayload>
    @ViewBuilder let advanced: () -> Advanced

    @Environment(\.hermesTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    init(
        model: ChatInstallModel, displayName: String, spec: BotAvatarSpec?,
        events: @escaping @Sendable () -> AsyncStream<ChatInstallChangedPayload>, @ViewBuilder advanced: @escaping () -> Advanced
    ) {
        _model = State(initialValue: model)
        self.displayName = displayName
        self.spec = spec
        self.events = events
        self.advanced = advanced
    }

    var body: some View {
        Group {
            if model.screen == .unsupported {
                advanced()
            } else {
                wizard
            }
        }
        .task {
            await model.load()
            for await payload in events() { await model.receive(payload) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
    }

    private var wizard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
                if let notice = model.notice { caption(noticeText(notice), identifier: "chatInstallNotice") }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(theme.palette.sheetBackground).ignoresSafeArea())
        .navigationTitle(Text("Slack"))
        .toolbarTitleDisplayMode(.inline)
        .accessibilityIdentifier("chatInstallScreen")
        .safeAreaInset(edge: .bottom, spacing: 0) { primary }
        .confirmationDialog(Text("Disconnect \(displayName) from Slack?"), isPresented: $confirmsDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await model.disconnect() } }
                .accessibilityIdentifier("chatInstallDisconnectConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(displayName) leaves every channel and stops answering in Slack.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.screen {
        case .loading:
            DelayedReveal { ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("chatInstallLoading") }
        case .unavailable:
            header(String(localized: "Pal can't reach Slack setup right now"), String(localized: "Check your connection, then try again."))
        case .unsupported:
            EmptyView()
        case .providers:
            providers
        case .intro(let again):
            intro(again: again)
        case .credential:
            credential
        case .setup(let task):
            checklist
            if let task { manualTask(task) }
        case .allow:
            allow
        case .ready:
            ready
        case .error(let code, _):
            header(String(localized: "Setup stopped"), errorText(code))
                .accessibilityIdentifier("chatInstallError")
        }
    }

    private var providers: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(String(localized: "Where should \(displayName) work?"), String(localized: "Pick the chat app to add \(displayName) to."))
            ForEach(model.providers, id: \.providerId) { provider in
                PillButton(provider.providerId.capitalized, accessibilityIdentifier: "chatInstallProvider-\(provider.providerId)") {
                    Task { await model.choose(provider) }
                }
            }
        }
    }

    private func intro(again: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SlackMark().frame(width: 28, height: 28).accessibilityHidden(true)
            header(
                again ? String(localized: "Add \(displayName) to Slack again") : String(localized: "Add \(displayName) to Slack"),
                String(localized: "\(displayName) joins your workspace as its own member. Only you can chat with it.")
            )
            numbered([
                String(localized: "Copy a setup code from Slack. Pal shows you where."),
                String(localized: "Pal creates \(displayName)'s Slack app with its name and picture."),
                String(localized: "Click Allow in Slack, then pick the channels \(displayName) joins."),
            ], identifier: "chatInstallIntroSteps")
            preview
            NavigationLink { advanced() } label: {
                Text("Advanced: paste tokens").hermesText(.rowSubtitle)
            }
            .accessibilityIdentifier("chatInstallAdvanced")
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let identity = model.identityPreview(name: displayName) {
            HStack(spacing: 12) {
                if let spec { BotAvatarView(spec: spec, size: 44, animated: false).frame(width: 44, height: 44) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.displayName).hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textPrimary))
                    Text("@\(identity.username)").hermesText(.rowSubtitle).foregroundStyle(Color(theme.palette.textSecondary))
                }
                Spacer(minLength: 0)
                Text("App").hermesText(.chip).foregroundStyle(Color(theme.palette.textSecondary))
            }
            .padding(14)
            .kanbanGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("In Slack: \(identity.displayName), @\(identity.username)"))
            .accessibilityIdentifier("chatInstallPreview")
        }
    }

    private var credential: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(String(localized: "Get a setup code from Slack"), String(localized: "You do this once for each workspace. Pal keeps it safe and renews it."))
            PillButton(String(localized: "Open Slack"), accessibilityIdentifier: "chatInstallOpenSlackApps") {
                if let url = URL(string: "https://api.slack.com/apps") { ExternalLink.open(url) }
            }
            numbered([
                String(localized: "Sign in, then find Your App Configuration Tokens at the bottom of the page."),
                String(localized: "Click Generate Token, choose your workspace, then Generate."),
                String(localized: "Click Copy next to the access token and come back here. Then do the same for the refresh token."),
            ], identifier: "chatInstallCredentialSteps")
            slot(String(localized: "Access token"), filled: access != nil, identifier: "chatInstallAccessSlot")
            slot(String(localized: "Refresh token"), filled: refresh != nil, identifier: "chatInstallRefreshSlot")
            ChatCredentialPaste(accepts: [.configAccess, .configRefresh], identifier: "chatInstallPasteCredential") { kind, token in
                if kind == .configAccess { access = token } else { refresh = token }
            }
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(String(localized: "Setting up \(displayName)"), String(localized: "Pal does most of this for you. You can leave and come back on any device."))
            ForEach(model.checklist) { item in
                HStack(spacing: 10) {
                    Group {
                        switch item.status {
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(theme.palette.accentBlue))
                        case .active: ProgressView().controlSize(.small)
                        case .pending: Image(systemName: "circle").foregroundStyle(Color(theme.palette.textSecondary))
                        }
                    }
                    .frame(width: 20)
                    Text(checklistTitle(item.kind)).hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textPrimary))
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(statusLabel(item.status)))
                .accessibilityIdentifier("chatInstallCheck-\(checklistId(item.kind))")
            }
        }
    }

    @ViewBuilder
    private func manualTask(_ task: ChatProviderCapability) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(taskTitle(task)).hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textPrimary))
                .accessibilityAddTraits(.isHeader)
            caption(taskBody(task), identifier: "chatInstallTaskBody")
            ForEach(model.secondaryActions, id: \.self) { action in secondary(action) }
            switch task {
            case .setIcon:
                if let spec {
                    PillButton(ChatAvatarExport.actionTitle, accessibilityIdentifier: "chatInstallSaveAvatar") {
                        Task {
                            guard let image = ChatAvatarExport.render(spec: spec, background: Color(theme.palette.sheetBackground)) else { return }
                            avatarSaved = await ChatAvatarExport.deliver(image, name: displayName)
                        }
                    }
                    if avatarSaved { caption(ChatAvatarExport.explanation, identifier: "chatInstallAvatarSaved") }
                }
            case .appLevelCredential:
                slot(String(localized: "App key"), filled: appKey != nil, identifier: "chatInstallAppKeySlot")
                ChatCredentialPaste(accepts: [.appLevel], identifier: "chatInstallPasteAppKey") { _, token in appKey = token }
            default:
                EmptyView()
            }
        }
        .padding(14)
        .kanbanGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("chatInstallTask-\(task.rawValue)")
    }

    private var allow: some View {
        VStack(alignment: .leading, spacing: 12) {
            checklist
            caption(
                String(localized: "Slack opens in your browser. Click Allow, then come back to Pal. If your workspace needs an admin to approve new apps, send them the message below."),
                identifier: "chatInstallAllowBody"
            )
            ForEach(model.secondaryActions, id: \.self) { action in secondary(action) }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(
                String(localized: "\(displayName) is in Slack"),
                model.snapshot?.installation.map { String(localized: "Connected to \($0.workspaceName)") } ?? String(localized: "Connected")
            )
            .accessibilityIdentifier("chatInstallReady")
            Text("Channels").hermesText(.sectionCaption).foregroundStyle(Color(theme.palette.textSecondary))
            TextField(String(localized: "Search channels"), text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("chatInstallChannelSearch")
            ForEach(model.spaces.filter { search.isEmpty || $0.space.name.localizedCaseInsensitiveContains(search) }) { row in
                spaceRow(row)
            }
            PillButton(String(localized: "Check again"), accessibilityIdentifier: "chatInstallRefreshChannels") {
                Task { await model.refreshSpaces() }
            }
            PillButton(String(localized: "Disconnect"), accessibilityIdentifier: "chatInstallDisconnect") { confirmsDisconnect = true }
        }
    }

    private func spaceRow(_ row: ChatSpaceRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: row.space.kind == .private ? "lock" : "number").accessibilityHidden(true)
                Text(row.space.name).hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textPrimary))
                Spacer()
                switch row.status {
                case .live:
                    Label(String(localized: "Live"), systemImage: "checkmark.circle.fill").hermesText(.chip)
                        .accessibilityIdentifier("chatInstallSpaceLive-\(row.id)")
                case .joining:
                    Text("Joining").hermesText(.chip)
                case .available:
                    PillButton(String(localized: "Add"), kind: .accent, accessibilityIdentifier: "chatInstallJoin-\(row.id)") {
                        Task { await model.join(row.id) }
                    }
                case .needsInvite:
                    if row.invite == nil {
                        PillButton(String(localized: "Add"), accessibilityIdentifier: "chatInstallJoin-\(row.id)") {
                            Task { await model.join(row.id) }
                        }
                    } else {
                        Text("Waiting for invite").hermesText(.chip).accessibilityIdentifier("chatInstallSpaceWaiting-\(row.id)")
                    }
                }
            }
            if let invite = row.invite {
                caption(String(localized: "Private channels need an invite. Paste this message in the channel."), identifier: "chatInstallInviteBody-\(row.id)")
                HStack {
                    if let text = invite.copyText { secondary(.copy(text), identifier: "chatInstallCopyInvite-\(row.id)") }
                    if let link = invite.link.flatMap(URL.init(string:)) { secondary(.openLink(link), identifier: "chatInstallOpenChannel-\(row.id)") }
                }
            }
        }
        .padding(12)
        .kanbanGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("chatInstallSpace-\(row.id)")
    }

    @ViewBuilder
    private var primary: some View {
        if let action = model.primaryAction {
            PillButton(primaryTitle(action), kind: .accent, size: .large, isBusy: model.isWorking, accessibilityIdentifier: "chatInstallPrimary") {
                perform(action)
            }
            .disabled(!canPerform(action))
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
        }
    }

    private func canPerform(_ action: ChatInstallAction) -> Bool {
        switch action {
        case .saveCredential: access != nil && refresh != nil
        case .markDone(.appLevelCredential): appKey != nil
        default: !model.isWorking
        }
    }

    private func perform(_ action: ChatInstallAction) {
        switch action {
        case .reload: Task { await model.load() }
        case .begin: Task { await model.begin() }
        case .saveCredential:
            guard let token = access else { return }
            let renewal = refresh
            access = nil
            refresh = nil
            Task { await model.saveCredential(access: token, refresh: renewal) }
        case .markDone(let step):
            let key = step == .appLevelCredential ? appKey : nil
            appKey = nil
            Task { await model.markDone(step, secret: key) }
        case .openLink(let url), .openAllow(let url): ExternalLink.open(url)
        case .copy(let text):
            Pasteboard.string = text
            copied = text
        case .checkAgain: Task { await model.refresh() }
        case .copyAdminMessage:
            Pasteboard.string = String(localized: "Hi! I'd like to add my assistant \(displayName) to our Slack. It's an app that only I can chat with, in the channels I invite it to. Could you approve the \"\(displayName)\" app request? Thanks!")
            copied = "admin"
        case .fix: Task { await model.fix() }
        case .disconnect: confirmsDisconnect = true
        }
    }

    private func secondary(_ action: ChatInstallAction, identifier: String? = nil) -> some View {
        PillButton(secondaryTitle(action), accessibilityIdentifier: identifier ?? "chatInstall-\(secondaryId(action))") { perform(action) }
    }

    private func header(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 18, weight: .medium)).foregroundStyle(Color(theme.palette.textPrimary))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("chatInstallTitle")
            Text(body).hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textSecondary))
        }
    }

    private func caption(_ text: String, identifier: String) -> some View {
        Text(text).hermesText(.rowSubtitle).foregroundStyle(Color(theme.palette.textSecondary)).accessibilityIdentifier(identifier)
    }

    private func numbered(_ steps: [String], identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)").hermesText(.chip).foregroundStyle(Color(theme.palette.accentBlue))
                    Text(step).hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textPrimary))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func slot(_ title: String, filled: Bool, identifier: String) -> some View {
        Label(filled ? String(localized: "\(title) added") : String(localized: "\(title) not pasted yet"), systemImage: filled ? "checkmark.circle.fill" : "circle")
            .hermesText(.rowTitle)
            .foregroundStyle(Color(filled ? theme.palette.textPrimary : theme.palette.textSecondary))
            .accessibilityValue(Text(filled ? String(localized: "Added") : String(localized: "Empty")))
            .accessibilityIdentifier(identifier)
    }

    private func primaryTitle(_ action: ChatInstallAction) -> String {
        switch action {
        case .reload: String(localized: "Try again")
        case .begin: String(localized: "Create \(displayName) in Slack")
        case .saveCredential: String(localized: "Use these tokens")
        case .markDone: String(localized: "Done")
        case .openAllow: String(localized: "Add to Slack")
        case .checkAgain: String(localized: "Check again")
        case .fix(let fix): fixTitle(fix)
        default: secondaryTitle(action)
        }
    }

    private func secondaryTitle(_ action: ChatInstallAction) -> String {
        switch action {
        case .openLink: String(localized: "Open the Slack page")
        case .copy(let text): copied == text ? String(localized: "Copied") : String(localized: "Copy \(text)")
        case .checkAgain: String(localized: "I clicked Allow")
        case .copyAdminMessage: copied == "admin" ? String(localized: "Copied") : String(localized: "Copy a message for my admin")
        case .disconnect: String(localized: "Disconnect")
        default: ""
        }
    }

    private func secondaryId(_ action: ChatInstallAction) -> String {
        switch action {
        case .openLink: "OpenLink"
        case .copy: "Copy"
        case .checkAgain: "CheckAgain"
        case .copyAdminMessage: "CopyAdminMessage"
        default: "Action"
        }
    }

    private func fixTitle(_ fix: ChatFixAction) -> String {
        switch fix {
        case .reenterCredential: String(localized: "Paste a new setup code")
        case .restartAllow: String(localized: "Try Allow again")
        case .retry, .unknown: String(localized: "Try again")
        }
    }

    private func errorText(_ code: ChatSetupErrorCode) -> String {
        switch code {
        case .credentialRejected: String(localized: "Slack didn't accept that setup code. Copy a fresh one and paste it again.")
        case .credentialExpired: String(localized: "The setup code has expired. Copy a new one from Slack.")
        case .appCreateFailed: String(localized: "Pal couldn't create \(displayName)'s Slack app. Try again in a moment.")
        case .allowDenied: String(localized: "Slack didn't get your Allow. Open Slack again and click Allow.")
        case .installFailed: String(localized: "Pal couldn't finish adding \(displayName). Try again in a moment.")
        case .providerUnreachable, .unknown: String(localized: "Pal couldn't reach Slack. Check your connection, then try again.")
        }
    }

    private func noticeText(_ notice: ChatInstallNotice) -> String {
        switch notice {
        case .offline: String(localized: "Couldn't reach Pal. Check your connection and try again.")
        case .notSaved: String(localized: "That didn't go through. Try again.")
        }
    }

    private func taskTitle(_ task: ChatProviderCapability) -> String {
        switch task {
        case .setIcon: String(localized: "Add \(displayName)'s picture")
        case .appLevelCredential: String(localized: "Copy the app key")
        case .gatewayRedirect: String(localized: "Add Pal's return address")
        default: String(localized: "One more step")
        }
    }

    private func taskBody(_ task: ChatProviderCapability) -> String {
        switch task {
        case .setIcon: String(localized: "Slack doesn't let apps set their own picture. Save it, open the Slack page, and upload it under Display Information.")
        case .appLevelCredential: String(localized: "Open the Slack page, click Generate Token and Scopes under App-Level Tokens, add connections:write, then Copy and come back.")
        case .gatewayRedirect: String(localized: "Open the Slack page, add this address under Redirect URLs, then click Save URLs.")
        default: String(localized: "Follow the Slack page, then tap Done.")
        }
    }

    private func checklistTitle(_ kind: ChatSetupChecklistItem.Kind) -> String {
        switch kind {
        case .workspace: String(localized: "Connected to your workspace")
        case .createApp: String(localized: "Create \(displayName)'s app")
        case .manual(let task): taskTitle(task)
        case .allow: String(localized: "Allow in Slack")
        case .install: String(localized: "Finish adding \(displayName)")
        }
    }

    private func checklistId(_ kind: ChatSetupChecklistItem.Kind) -> String {
        switch kind {
        case .workspace: "workspace"
        case .createApp: "createApp"
        case .manual(let task): task.rawValue
        case .allow: "allow"
        case .install: "install"
        }
    }

    private func statusLabel(_ status: ChatSetupChecklistItem.Status) -> String {
        switch status {
        case .done: String(localized: "Done")
        case .active: String(localized: "In progress")
        case .pending: String(localized: "Not yet")
        }
    }
}

struct SlackEntryView: View {
    let botName: String
    let displayName: String
    let spec: BotAvatarSpec?
    let services: BotsServices
    let source: ChatInstallSource

    @State private var tokensConnected: Bool?

    var body: some View {
        Group {
            switch tokensConnected {
            case .none:
                DelayedReveal { ProgressView() }
            case .some(true):
                legacy
            case .some(false):
                ChatInstallView(
                    model: ChatInstallModel(botName: botName, preferredProvider: "slack", client: source.client),
                    displayName: displayName, spec: spec, events: source.events
                ) { legacy }
            }
        }
        .task {
            guard tokensConnected == nil else { return }
            let status = try? await services.slack.status(profile: botName)
            tokensConnected = status.map { $0.connection != .notConnected } ?? false
        }
    }

    private var legacy: some View {
        SlackView(model: SlackModel(botName: botName, displayName: displayName, services: services))
    }
}
