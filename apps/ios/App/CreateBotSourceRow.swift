import PalDesign
import SwiftUI

struct CreateBotSourceRow: View {
    @Bindable var model: CreateBotModel
    let roster: RosterModel

    @Environment(\.hermesTheme) private var theme

    private struct Source: Identifiable {
        let name: String
        let title: String
        var id: String { name }
    }

    private var sources: [Source] {
        let rows = roster.bots.filter(\.isDefault) + roster.bots.filter { !$0.isDefault }
        var options = rows.map { Source(name: $0.name, title: $0.isDefault ? String(localized: "\($0.displayName) (main bot)") : $0.displayName) }
        if !options.contains(where: { $0.name == CreateBotModel.mainBot }) {
            options.insert(Source(name: CreateBotModel.mainBot, title: String(localized: "Main bot")), at: 0)
        }
        return options
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("Start from")
                .hermesText(.rowTitle)
                .foregroundStyle(Color(theme.palette.textPrimary))
            Spacer(minLength: 12)
            Picker("Start from", selection: $model.cloneFrom) {
                ForEach(sources) { source in Text(source.title).tag(source.name) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(model.isCreating)
            .accessibilityLabel(Text("Start from"))
            .accessibilityIdentifier("createBotStartFrom")
        }
        .padding(.horizontal, PalMetrics.nameFieldHorizontalMargin)
    }
}
