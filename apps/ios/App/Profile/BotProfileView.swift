import HermesBotProfile
import HermesDesign
import SwiftUI

struct BotProfileView: View {
    @State private var model: BotProfileModel
    let router: AppRouter

    @Environment(\.hermesTheme) private var theme

    init(model: BotProfileModel, router: AppRouter) {
        _model = State(initialValue: model)
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
        .toast($model.toast)
        .sheet(item: Binding(get: { model.editing }, set: { if $0 == nil { model.endEditing() } })) { editing in
            EditBotSheet(model: editing) { model.endEditing() }
        }
        .confirmationDialog(
            Text("Replace Primary Bot?"),
            isPresented: $model.confirmsReplacePrimary,
            titleVisibility: .visible
        ) {
            Button("Replace") { Task { await model.replacePrimary() } }
                .accessibilityIdentifier("replacePrimaryConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.displayName) becomes your primary bot. Nothing is copied or deleted.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { Task { await model.shareTemplate() } } label: {
                CircleIcon(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(model.isSharing)
            .accessibilityLabel(Text("Share as Template"))
            .accessibilityIdentifier("profileShareButton")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if !model.isPrimary {
                    Button("Replace Primary Bot…", systemImage: "star") { model.confirmsReplacePrimary = true }
                        .accessibilityIdentifier("profileReplacePrimary")
                }
                Button("Copy ID", systemImage: "doc.on.doc") { model.copyID() }
                    .accessibilityIdentifier("profileCopyID")
            } label: {
                CircleIcon(systemName: "ellipsis")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("More"))
            .accessibilityIdentifier("profileMoreButton")
        }
        .sharedBackgroundVisibility(.hidden)
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
            GroupedCard(separatorInset: HermesMetrics.iconRowSeparatorInset, accessibilityIdentifier: "profileLibraryCard") {
                SettingsRow.navigate(
                    String(localized: "Library"),
                    icon: .symbol("books.vertical"),
                    accessibilityIdentifier: "profileLibraryRow"
                ) { router.push(.library(botName: model.botName)) }
                SettingsRow.value(
                    String(localized: "Computer"),
                    value: model.computer?.text ?? "",
                    icon: .symbol("display"),
                    accessibilityIdentifier: "profileComputerRow"
                )
            }
            .padding(.top, ProfileMetrics.editToCards)
            SectionCaption(String(localized: "Configure bot"), accessibilityIdentifier: "profileConfigureCaption")
                .padding(.top, ProfileMetrics.cardToCaption)
                .padding(.bottom, ProfileMetrics.captionToCard)
            GroupedCard(separatorInset: HermesMetrics.iconRowSeparatorInset, accessibilityIdentifier: "profileConfigureCard") {
                SettingsRow.navigate(
                    String(localized: "Add to Slack"),
                    icon: .custom(SlackMark(style: .mono(Color(theme.palette.textSecondary))).frame(width: 18, height: 18)),
                    accessibilityIdentifier: "profileSlackRow"
                ) { router.push(.slack(botName: model.botName)) }
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
                .padding(.horizontal, HermesMetrics.screenMargin + HermesMetrics.rowInset)
                .padding(.top, ProfileMetrics.toggleToFooter)
                .accessibilityIdentifier("profileNotificationsFooter")
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
