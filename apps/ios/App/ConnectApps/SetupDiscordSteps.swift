import PalConnect
import PalDesign
import SwiftUI

struct SetupServerPicker: View {
    let model: SetupGuideModel

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
            if let name = model.botName {
                CardFootnote(String(localized: "Your bot: \(name)"), accessibilityIdentifier: "setupGuideBotName")
            }
            if let servers = model.servers {
                if servers.guilds.isEmpty {
                    CardFootnote(
                        String(localized: "The bot isn't in any server yet. Go back and open the invite link."),
                        accessibilityIdentifier: "setupGuideNoServers"
                    )
                } else {
                    GroupedCard(accessibilityIdentifier: "setupGuideServers") {
                        VStack(spacing: 0) {
                            ForEach(servers.guilds) { guild in row(guild) }
                        }
                    }
                }
            } else {
                DelayedProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: model.step.id) { await model.loadServers() }
    }

    private func row(_ guild: DiscordGuild) -> some View {
        let picked = model.selectedGuilds.contains(guild.id)
        return Button { model.toggleGuild(guild.id) } label: {
            HStack(spacing: 12) {
                Text(guild.name)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Color(picked ? theme.palette.textPrimary : theme.palette.textSecondary))
            }
            .padding(.horizontal, PalMetrics.rowInset)
            .padding(.vertical, PalMetrics.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier("setupGuideServer-\(guild.id)")
    }
}

struct SetupAccessChoice: View {
    let model: SetupGuideModel

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
            GroupedCard(accessibilityIdentifier: "setupGuideAccess") {
                Toggle(String(localized: "Read only"), isOn: Binding(get: { model.readOnly }, set: { model.setReadOnly($0) }))
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .padding(.horizontal, PalMetrics.rowInset)
                    .padding(.vertical, PalMetrics.rowVerticalPadding)
                    .accessibilityIdentifier("setupGuideReadOnly")
            }
            PillButton(String(localized: "Save"), kind: .accent, size: .large, accessibilityIdentifier: "setupGuideSubmit") {
                Task { await model.saveAccess() }
            }
            .disabled(model.selectedGuilds.isEmpty)
            .padding(.horizontal, PalMetrics.screenMargin)
        }
        .task(id: model.step.id) { await model.loadServers() }
    }
}
