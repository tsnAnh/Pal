import PalBotProfile
import PalDesign
import SwiftUI

struct BotToolsetsView: View {
    @State private var model: BotToolsetsModel
    let displayName: String

    @Environment(\.hermesTheme) private var theme

    init(model: BotToolsetsModel, displayName: String) {
        _model = State(initialValue: model)
        self.displayName = displayName
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                switch model.phase {
                case .loading:
                    DelayedProgressView().padding(.top, 40).accessibilityIdentifier("botToolsLoading")
                case .failed:
                    FailureCard(message: String(localized: "Couldn't load this bot's tools."), identifier: "botToolsFailure") {
                        Task { await model.load() }
                    }
                case .unavailable:
                    CardFootnote(
                        String(localized: "Choosing tools isn't available on this connection yet."),
                        accessibilityIdentifier: "botToolsUnavailable")
                        .padding(.top, PalMetrics.cardGap)
                case .ready:
                    overview
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Color(theme.palette.sheetBackground).ignoresSafeArea())
        .accessibilityIdentifier("botToolsScreen")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Tools")
                    .hermesText(.sheetTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .accessibilityAddTraits(.isHeader)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await model.commit() } }
                    .disabled(!model.canSave)
                    .accessibilityIdentifier("botToolsSave")
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private var overview: some View {
        SectionCaption(String(localized: "What \(displayName) can use"), accessibilityIdentifier: "botToolsCaption")
            .padding(.bottom, PalMetrics.captionToCardGap)
        GroupedCard(accessibilityIdentifier: "botToolsCard") {
            ForEach(model.items) { toolset in
                SettingsRow.toggle(
                    toolset.label,
                    subtitle: subtitle(for: toolset),
                    isOn: Binding(
                        get: { model.isOn(toolset.name) },
                        set: { model.toggle(toolset.name, on: $0) }),
                    accessibilityIdentifier: "botTools-\(toolset.name)")
                .disabled(model.isSaving)
            }
        }
        CardFootnote(
            model.needsSelection
                ? String(localized: "Keep at least one tool group on, or use the standard set.")
                : String(localized: "Applies to new conversations. Ones already open keep their tools."),
            accessibilityIdentifier: "botToolsFootnote")
        if model.isPinned {
            GroupedCard(accessibilityIdentifier: "botToolsStandardCard") {
                SettingsRow.navigate(
                    String(localized: "Use the standard set"),
                    accessibilityIdentifier: "botToolsStandard"
                ) { Task { await model.useStandardSet() } }
                .disabled(model.isSaving)
            }
            .padding(.top, PalMetrics.cardGap)
        }
        statusLine
    }

    private func subtitle(for toolset: Toolset) -> String {
        let count = String(localized: "\(toolset.toolCount) tools")
        return toolset.summary.isEmpty ? count : "\(toolset.summary) · \(count)"
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.save {
        case .idle:
            EmptyView()
        case .saving:
            CardFootnote(String(localized: "Saving…"), accessibilityIdentifier: "botToolsStatus")
        case .saved:
            CardFootnote(
                String(localized: "Saved. New conversations use these tools; ones already open keep theirs."),
                accessibilityIdentifier: "botToolsStatus")
        case .failed:
            Text("Couldn't save the tools. Nothing was changed.")
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.destructive))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset - 3)
                .padding(.top, PalMetrics.captionToCardGap)
                .accessibilityIdentifier("botToolsStatus")
        }
    }
}
