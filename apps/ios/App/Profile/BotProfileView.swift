import PalBotProfile
import PalConnect
import PalDesign
import SwiftUI

struct BotProfileView: View {
    @State private var model: BotProfileModel
    @State private var suggestions: ConnectedServicesModel
    let router: AppRouter

    @Environment(\.hermesTheme) private var theme
    @Environment(ActionAutoApprove.self) private var autoApprove

    init(model: BotProfileModel, suggestions: ConnectedServicesModel, router: AppRouter) {
        _model = State(initialValue: model)
        _suggestions = State(initialValue: suggestions)
        self.router = router
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                configureCards
            }
            .padding(.bottom, 32)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Color(theme.palette.sheetBackground).ignoresSafeArea())
        .accessibilityIdentifier("botProfileScreen")
        .toolbar { toolbar }
        .toolbarTitleDisplayMode(.inline)
        .task { await model.load() }
        .task { await suggestions.load() }
        .task(id: model.row?.conversationID) { await autoApprove.load(sessionID: model.row?.conversationID) }
        .toast($model.toast)
        .sheet(item: Binding(get: { model.editing }, set: { if $0 == nil { model.endEditing() } })) { editing in
            EditBotSheet(model: editing) { model.endEditing() }
                .macSheetFrame()
        }
        .macConfirm(isPresented: $model.confirmsReplacePrimary) {
            MacDialogContent(
                String(localized: "Replace Primary Bot?"),
                message: String(localized: "\(model.displayName) becomes your primary bot. Nothing is copied or deleted."),
                actions: [
                    MacDialogAction(String(localized: "Replace"), identifier: "replacePrimaryConfirm") { Task { await model.replacePrimary() } },
                    MacDialogAction(String(localized: "Cancel"), role: .cancel),
                ]
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .trailingBar) {
            Button { Task { await model.shareTemplate() } } label: {
                PalIcon("square.and.arrow.up")
            }
            .disabled(model.isSharing)
            .accessibilityLabel(Text("Share as Template"))
            .accessibilityIdentifier("profileShareButton")
        }
        ToolbarItem(placement: .trailingBar) {
            Menu {
                if !model.isPrimary {
                    Button { model.confirmsReplacePrimary = true } label: { Label("Replace Primary Bot…", palIcon: "star") }
                        .accessibilityIdentifier("profileReplacePrimary")
                }
                Button { model.copyID() } label: { Label("Copy ID", palIcon: "doc.on.doc") }
                    .accessibilityIdentifier("profileCopyID")
            } label: {
                PalIcon("ellipsis")
            }
            .accessibilityLabel(Text("More"))
            .accessibilityIdentifier("profileMoreButton")
        }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            AvatarBadge(diameter: ProfileMetrics.avatarDiameter, showsPrimaryBadge: model.isPrimary, accessibilityIdentifier: "profileAvatarArtwork") {
                if let spec = model.spec {
                    BotAvatarView(spec: spec, size: ProfileMetrics.avatarDiameter)
                } else {
                    Color.clear
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(model.displayName))
            .accessibilityValue(Text(model.isPrimary ? "Primary bot" : ""))
            .accessibilityIdentifier("profileAvatar")
            .padding(.top, ProfileMetrics.avatarTop)
            Text(model.displayName)
                .font(.system(size: ProfileMetrics.nameSize))
                .foregroundStyle(Color(theme.palette.textPrimary))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, ProfileMetrics.avatarToName)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("profileName")
            Button("Edit") { model.beginEditing() }
                .buttonStyle(ProfileEditPillStyle())
                .disabled(model.profile == nil)
                .padding(.top, ProfileMetrics.nameToEdit)
                .accessibilityIdentifier("profileEditButton")
        }
        .frame(maxWidth: .infinity)
    }

    private var configureCards: some View {
        VStack(spacing: 0) {
            GroupedCard(accessibilityIdentifier: "profileLibraryCard") {
                SettingsRow.navigate(
                    String(localized: "Library"),
                    icon: .symbol("books.vertical"),
                    accessibilityIdentifier: "profileLibraryRow"
                ) { router.push(.library(botName: model.botName)) }
                SettingsRow.navigate(
                    String(localized: "Computer"),
                    value: model.computer?.text ?? "",
                    icon: .symbol("display"),
                    accessibilityIdentifier: "profileComputerRow"
                ) { router.push(.computer(botName: model.botName)) }
            }
            .padding(.top, ProfileMetrics.editToCards)
            SectionCaption(String(localized: "Configure bot"), accessibilityIdentifier: "profileConfigureCaption")
                .padding(.top, ProfileMetrics.cardToCaption)
                .padding(.bottom, ProfileMetrics.captionToCard)
            GroupedCard(accessibilityIdentifier: "profileConfigureCard") {
                ForEach(suggestions.visibleSuggestions, id: \.self) { suggestion in
                    switch suggestion {
                    case .addToSlack:
                        SettingsRow.navigate(
                            String(localized: "Add to Slack"),
                            icon: .custom(SlackMark(style: .mono(Color(theme.palette.textSecondary))).frame(width: 18, height: 18)),
                            accessibilityIdentifier: "profileSlackRow"
                        ) { router.push(.slack(botName: model.botName)) }
                    }
                }
                SettingsRow.navigate(
                    String(localized: "Model"),
                    icon: .symbol("cpu"),
                    accessibilityIdentifier: "profileModelRow"
                ) { router.push(.botModel(botName: model.botName)) }
                SettingsRow.navigate(
                    String(localized: "Connect Telegram"),
                    icon: .symbol("paperplane.fill"),
                    accessibilityIdentifier: "profileTelegramRow"
                ) { router.push(.telegram(botName: model.botName)) }
                SettingsRow.navigate(
                    String(localized: "Messaging"),
                    icon: .symbol("bubble.left.and.bubble.right"),
                    accessibilityIdentifier: "profileMessagingRow"
                ) { router.push(.messagingSettings(botName: model.botName)) }
                SettingsRow.navigate(
                    String(localized: "Keys"),
                    icon: .symbol("key"),
                    accessibilityIdentifier: "profileKeysRow"
                ) { router.push(.botKeys(botName: model.botName)) }
                SettingsRow.navigate(
                    String(localized: "Vault"),
                    icon: .symbol("lock"),
                    accessibilityIdentifier: "profileVaultRow"
                ) { router.push(.botVault(botName: model.botName)) }
                SettingsRow.navigate(
                    String(localized: "Routines"),
                    value: model.routinesText,
                    icon: .symbol("clock"),
                    accessibilityIdentifier: "profileRoutinesRow"
                ) { router.push(.routines(botName: model.botName)) }
            }
            GroupedCard(accessibilityIdentifier: "profileNotificationsCard") {
                SettingsRow.toggle(
                    String(localized: "Notifications"),
                    isOn: Binding(get: { model.notificationsOn }, set: { model.setNotifications($0) }),
                    minimumHeight: ProfileMetrics.toggleRowHeight,
                    accessibilityIdentifier: "profileNotificationsToggle"
                )
            }
            .padding(.top, ProfileMetrics.cardGap)
            Text("Get notified when this Bot finishes or is waiting for you")
                .hermesText(.footnoteCaption)
                .foregroundStyle(Color(theme.palette.sectionCaption))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset)
                .padding(.top, ProfileMetrics.toggleToFooter)
                .accessibilityIdentifier("profileNotificationsFooter")
            AutoApproveCard(sessionID: model.row?.conversationID, upworkConnected: suggestions.services.isConnected(.upwork))
        }
    }
}

private struct ProfileEditPillStyle: ButtonStyle {
    @Environment(\.hermesTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: ProfileMetrics.editPillTextSize))
            .foregroundStyle(Color(theme.palette.pillText))
            .padding(.horizontal, ProfileMetrics.editPillPadding)
            .frame(height: ProfileMetrics.editPillHeight)
            .background(Color(theme.palette.pillFill), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

enum ProfileMetrics {
    static let avatarDiameter: CGFloat = 88
    static let avatarTop: CGFloat = 19
    static let avatarToName: CGFloat = 18
    static let nameSize: CGFloat = 20
    static let nameToEdit: CGFloat = 11
    static let editPillHeight: CGFloat = 37
    static let editPillPadding: CGFloat = 12
    static let editPillTextSize: CGFloat = 15
    static let editToCards: CGFloat = 25
    static let cardToCaption: CGFloat = 25
    static let captionToCard: CGFloat = 10
    static let cardGap: CGFloat = 25
    static let toggleRowHeight: CGFloat = 57
    static let toggleToFooter: CGFloat = 11
}
