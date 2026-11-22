import PalBotProfile
import PalDesign
import SwiftUI

struct MessagingSettingsView: View {
    @State private var model: MessagingSettingsModel

    @Environment(\.hermesTheme) private var theme

    init(model: MessagingSettingsModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        BotSettingsScreen(title: String(localized: "Messaging settings"), identifier: "messagingSettingsScreen") {
            content
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            DelayedProgressView().accessibilityIdentifier("messagingSettingsLoading")
        case .unavailable:
            Button("Try again") { Task { await model.load() } }
                .buttonStyle(.glass)
                .accessibilityIdentifier("messagingSettingsRetry")
        case .ready:
            if model.restartNeeded {
                restartNotice
            }
            ForEach(model.platforms) { platform in
                platformSection(platform)
            }
        }
    }

    private var restartNotice: some View {
        Label(String(localized: "Restart the gateway for these changes to take effect."), palIcon: "arrow.triangle.2.circlepath")
            .hermesText(.rowSubtitle)
            .foregroundStyle(Color(theme.palette.textPrimary))
            .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset)
            .padding(.bottom, PalMetrics.cardGap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("messagingRestartNeeded")
    }

    private func platformSection(_ platform: MessagingPlatform) -> some View {
        VStack(spacing: 0) {
            SectionCaption(platform.displayName, accessibilityIdentifier: "messagingCaption-\(platform.id)")
                .padding(.top, PalMetrics.cardGap)
                .padding(.bottom, PalMetrics.captionToCardGap)
            GroupedCard(accessibilityIdentifier: "messagingCard-\(platform.id)") {
                SettingsRow.toggle(
                    String(localized: "Enabled"),
                    isOn: Binding(
                        get: { platform.enabled },
                        set: { value in Task { await model.setEnabled(value, in: platform) } }
                    ),
                    accessibilityIdentifier: "messagingEnabled-\(platform.id)"
                )
                ForEach(platform.credentials) { credential in
                    SettingsRow.value(
                        credential.label,
                        value: credential.isSet ? String(localized: "Set") : String(localized: "Not set"),
                        accessibilityIdentifier: "messagingCredential-\(credential.key)"
                    )
                }
            }
            if !platform.settings.isEmpty {
                GroupedCard(accessibilityIdentifier: "messagingFields-\(platform.id)") {
                    ForEach(platform.settings) { setting in
                        settingField(setting)
                    }
                }
                .padding(.top, PalMetrics.cardGap)
                saveRow(platform)
            }
        }
    }

    private func settingField(_ setting: MessagingSetting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(setting.label)
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.textSecondary))
            TextField("", text: Binding(get: { model.text(for: setting) }, set: { model.drafts[setting.key] = $0 }), prompt: Text(hint(setting.kind)))
                .neverAutocapitalized()
                .autocorrectionDisabled()
                .accessibilityLabel(Text(setting.label))
                .accessibilityIdentifier("messagingField-\(setting.key)")
            if let error = model.fieldErrors[setting.key] {
                Text(error)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .accessibilityIdentifier("messagingFieldError-\(setting.key)")
            }
        }
        .padding(.horizontal, PalMetrics.rowInset)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ kind: MessagingSettingKind) -> String {
        switch kind {
        case .allowlist: String(localized: "Separate IDs with commas")
        case .homeChannel: String(localized: "Channel ID")
        }
    }

    private func saveRow(_ platform: MessagingPlatform) -> some View {
        VStack(spacing: 8) {
            HStack {
                Spacer(minLength: 0)
                Button {
                    Task { await model.save(platform) }
                } label: {
                    if model.isSaving(platform) {
                        Text("Saving…")
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.glass)
                .disabled(!model.isDirty(platform) || model.isSaving(platform))
                .accessibilityIdentifier("messagingSave-\(platform.id)")
            }
            .padding(.horizontal, PalMetrics.screenMargin)
            switch model.saveStates[platform.id] {
            case .saved:
                BotSettingsBanner(kind: .saved, text: String(localized: "Saved"), identifier: "messagingSaved-\(platform.id)")
            case .failed(let message):
                BotSettingsBanner(
                    kind: .failed, text: message, identifier: "messagingFailed-\(platform.id)",
                    retry: { Task { await model.save(platform) } }
                )
            case .saving, nil:
                EmptyView()
            }
        }
        .padding(.top, PalMetrics.cardGap)
    }
}
