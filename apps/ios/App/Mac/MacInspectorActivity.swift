#if os(macOS)
import PalBotProfile
import PalConnect
import PalDesign
import PalDiagnostics
import SwiftUI

struct InspectorActivity: View {
    let botName: String
    let router: AppRouter
    let profile: BotProfileModel
    let routines: RoutinesModel
    let suggestions: ConnectedServicesModel
    @Binding var creation: NewRoutineModel?

    var body: some View {
        VStack(spacing: 0) {
            InspectorRoutinesSection(routines: routines, creation: $creation)
            InspectorSuggestedSection(botName: botName, router: router, suggestions: suggestions)
            InspectorComputerSection(botName: botName, router: router, profile: profile)
            InspectorSection(title: String(localized: "Model"), identifier: "inspectorModel") {
                InspectorLinkRow(identifier: "profileModelRow", router: router, route: .botModel(botName: botName)) {
                    PalIcon("cpu", ink: .secondary).font(.system(size: 13)).frame(width: 18)
                    Text("Model, effort and backups").font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                    Spacer(minLength: 0)
                    PalIcon("chevron.right", ink: .tertiary).font(.system(size: 9, weight: .semibold))
                }
            }
            InspectorSection(title: String(localized: "Messaging"), identifier: "inspectorMessaging") {
                InspectorLinkRow(identifier: "profileMessagingRow", router: router, route: .messagingSettings(botName: botName)) {
                    PalIcon("bubble.left.and.bubble.right", ink: .secondary).font(.system(size: 13)).frame(width: 18)
                    Text("Messaging settings").font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                    Spacer(minLength: 0)
                    PalIcon("chevron.right", ink: .tertiary).font(.system(size: 9, weight: .semibold))
                }
                InspectorLinkRow(identifier: "profileKeysRow", router: router, route: .botKeys(botName: botName)) {
                    PalIcon("key", ink: .secondary).font(.system(size: 13)).frame(width: 18)
                    Text("Keys").font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                    Spacer(minLength: 0)
                    PalIcon("chevron.right", ink: .tertiary).font(.system(size: 9, weight: .semibold))
                }
                InspectorLinkRow(identifier: "profileVaultRow", router: router, route: .botVault(botName: botName)) {
                    PalIcon("lock", ink: .secondary).font(.system(size: 13)).frame(width: 18)
                    Text("Vault").font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                    Spacer(minLength: 0)
                    PalIcon("chevron.right", ink: .tertiary).font(.system(size: 9, weight: .semibold))
                }
                InspectorLinkRow(identifier: "profileTelegramRow", router: router, route: .telegram(botName: botName)) {
                    PalIcon("paperplane.fill", ink: .secondary).font(.system(size: 13)).frame(width: 18)
                    Text("Connect Telegram").font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                    Spacer(minLength: 0)
                    PalIcon("chevron.right", ink: .tertiary).font(.system(size: 9, weight: .semibold))
                }
            }
            InspectorNotificationsSection(profile: profile)
            InspectorUpworkSection(profile: profile, suggestions: suggestions)
        }
    }
}

private struct InspectorSuggestedSection: View {
    let botName: String
    let router: AppRouter
    let suggestions: ConnectedServicesModel
    @AppStorage("mac.inspector.suggestionsHidden") private var suggestionsHidden = false

    var body: some View {
        if !suggestionsHidden, !suggestions.visibleSuggestions.isEmpty {
            InspectorSection(title: String(localized: "Suggested"), identifier: "inspectorSuggested", accessory: {
                Button("Hide") { withAnimation(.snappy(duration: 0.18)) { suggestionsHidden = true } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PalTokens.textSecondary)
                    .accessibilityIdentifier("inspectorHideSuggested")
            }, content: {
                ForEach(suggestions.visibleSuggestions, id: \.self) { suggestion in
                    switch suggestion {
                    case .addToSlack:
                        InspectorLinkRow(identifier: "profileSlackRow", router: router, route: .slack(botName: botName)) {
                            SlackMark().frame(width: 14, height: 14)
                            Text("Add to Slack").font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                            Spacer(minLength: 0)
                            PalIcon("chevron.right", ink: .tertiary).font(.system(size: 9, weight: .semibold))
                        }
                    }
                }
            })
        }
    }
}

private struct InspectorComputerSection: View {
    let botName: String
    let router: AppRouter
    let profile: BotProfileModel

    var body: some View {
        InspectorSection(title: String(localized: "Computer"), identifier: "inspectorComputer") {
            InspectorLinkRow(identifier: "profileComputerRow", router: router, route: .computer(botName: botName)) {
                PalIcon("display", ink: .secondary).font(.system(size: 13)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bot's computer").font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                    Text(profile.computer?.text ?? " ").font(.system(size: 11)).foregroundStyle(PalTokens.textSecondary)
                }
                Spacer(minLength: 0)
                PalIcon("chevron.right", ink: .tertiary).font(.system(size: 9, weight: .semibold))
            }
        }
    }
}

private struct InspectorNotificationsSection: View {
    let profile: BotProfileModel

    var body: some View {
        InspectorSection(title: String(localized: "Notifications"), identifier: "inspectorNotifications") {
            InspectorRow(identifier: "profileNotificationsRow", action: nil) {
                Text("Notify me when this Bot is done").font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                Spacer(minLength: 8)
                Toggle("Notifications", isOn: Binding(get: { profile.notificationsOn }, set: { profile.setNotifications($0) }))
                    .labelsHidden()
                    .palSwitch()
                    .accessibilityIdentifier("profileNotificationsToggle")
            }
        }
    }
}

private struct InspectorUpworkSection: View {
    let profile: BotProfileModel
    let suggestions: ConnectedServicesModel

    @Environment(ActionAutoApprove.self) private var autoApprove

    var body: some View {
        let sessionID = profile.row?.conversationID
        let caption = autoApprove.didFail(sessionID)
            ? String(localized: "Couldn't change this. Try again.")
            : String(localized: "Off by default. Applies to this chat only.")
        if autoApprove.showsSwitch(sessionID: sessionID, upworkConnected: suggestions.services.isConnected(.upwork)) {
            InspectorSection(title: String(localized: "Upwork"), identifier: "inspectorUpwork") {
                InspectorRow(identifier: "autoApproveRow", action: nil) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Approve Upwork actions automatically in this chat").font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary)
                        Text(caption)
                            .font(.system(size: 11))
                            .foregroundStyle(PalTokens.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Toggle("Approve Upwork actions automatically in this chat", isOn: Binding(
                        get: { autoApprove.entry(sessionID)?.enabled ?? false },
                        set: { value in Task { await autoApprove.setEnabled(value, sessionID: sessionID) } }
                    ))
                    .labelsHidden()
                    .palSwitch()
                    .disabled(autoApprove.isPending(sessionID))
                    .accessibilityIdentifier("autoApproveToggle")
                }
            }
        }
    }
}

private struct InspectorRoutinesSection: View {
    let routines: RoutinesModel
    @Binding var creation: NewRoutineModel?

    var body: some View {
        InspectorSection(title: String(localized: "Upcoming"), identifier: "inspectorRoutines", first: true) {
            routinesList
        }
    }

    @ViewBuilder
    private var routinesList: some View {
        switch routines.phase {
        case .loading:
            DelayedProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 14)
        case .failed:
            InspectorRow(identifier: "routinesFailed", action: { Task { await routines.load() } }, content: {
                Text("Couldn't load routines. Try again.").font(.system(size: 12)).foregroundStyle(PalTokens.textSecondary)
                Spacer(minLength: 0)
            })
        case .ready where routines.routines.isEmpty:
            InspectorRow(identifier: "routinesEmpty", action: { creation = routines.creationModel() }, content: {
                Text("No routines yet. Add one").font(.system(size: 12)).foregroundStyle(PalTokens.textSecondary)
                Spacer(minLength: 0)
            })
        case .ready:
            VStack(spacing: 0) {
                ForEach(routines.routines) { routine in
                    InspectorRoutineRow(routine: routine) { enabled in
                        Task { await routines.setEnabled(enabled, for: routine) }
                    }
                    .equatable()
                }
            }
        }
    }
}

private struct InspectorRoutineRow: View, Equatable {
    let routine: Routine
    let setEnabled: (Bool) -> Void

    nonisolated static func == (lhs: InspectorRoutineRow, rhs: InspectorRoutineRow) -> Bool {
        lhs.routine == rhs.routine
    }

    var body: some View {
        let _ = PalPerf.event("inspector.routine-row.body") // swiftlint:disable:this redundant_discardable_let
        InspectorRow(identifier: "routine-\(routine.id)", action: nil) {
            PalIcon("clock", ink: .tertiary).font(.system(size: 13)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(routine.title).font(.system(size: 12)).foregroundStyle(PalTokens.textPrimary).lineLimit(1)
                Text(routine.caption()).font(.system(size: 11)).foregroundStyle(PalTokens.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Toggle(routine.title, isOn: Binding(get: { routine.isEnabled }, set: setEnabled))
                .labelsHidden()
                .palSwitch()
                .accessibilityLabel(Text(routine.title))
                .accessibilityIdentifier("routineToggle-\(routine.id)")
        }
    }
}

extension InspectorSection where Accessory == EmptyView {
    init(title: String, identifier: String, first: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title: title, identifier: identifier, first: first, accessory: { EmptyView() }, content: content)
    }
}

struct InspectorSection<Accessory: View, Content: View>: View {
    let title: String
    let identifier: String
    var first = false
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(PalTokens.textSecondary)
                Spacer()
                accessory
            }
            .padding(.horizontal, 11)
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity)
                .background(PalTokens.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.top, first ? 11 : 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

struct InspectorLinkRow<Content: View>: View {
    let identifier: String
    let router: AppRouter
    let route: AppRoute
    @ViewBuilder let content: Content

    var body: some View {
        InspectorRow(identifier: identifier, action: { router.push(route) }, content: { content })
    }
}

struct InspectorRow<Content: View>: View {
    let identifier: String
    let action: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier)
        } else {
            row.accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
        }
    }

    private var row: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(minHeight: 42)
            .contentShape(Rectangle())
    }
}
#endif
