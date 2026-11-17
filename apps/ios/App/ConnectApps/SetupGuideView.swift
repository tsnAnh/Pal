import PalConnect
import PalDesign
import SwiftUI

struct SetupGuideView: View {
    let model: SetupGuideModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetChrome(
            title: model.app.name,
            accessibilityIdentifier: "setupGuide",
            leadingAccessibilityIdentifier: "setupGuideCancel",
            onLeading: { dismiss() },
            content: { content }
        )
        .task { await model.start() }
        .alert(String(localized: "Replace the saved client?"), isPresented: Binding(get: { model.confirmsReplace }, set: { model.confirmsReplace = $0 })) {
            Button(String(localized: "Replace"), role: .destructive) { model.replaceClient() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("The new client replaces the one saved on your Pal.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading, .working:
            DelayedProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("setupGuideBusy")
        case .steps:
            SetupGuideStepView(model: model)
        case .saved:
            SavedClientView(model: model)
        case .problem(let problem):
            OAuthClientProblemView(problem: problem, name: model.app.name, identifierPrefix: "setupGuide") {
                Task { await model.retry(problem) }
            }
        }
    }
}

private struct SavedClientView: View {
    let model: SetupGuideModel

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
            VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
                SectionCaption(String(localized: "Your client"), accessibilityIdentifier: "setupGuideSavedCaption")
                GroupedCard(accessibilityIdentifier: "setupGuideSavedCard") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: "••••••••••••")
                            .hermesText(.rowTitle)
                            .foregroundStyle(Color(theme.palette.textPrimary))
                            .accessibilityLabel(Text("Saved client"))
                            .accessibilityIdentifier("setupGuideSavedValue")
                        Text("Saved on your Pal for every device. It can't be read back.")
                            .hermesText(.rowSubtitle)
                            .foregroundStyle(Color(theme.palette.textSecondary))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PalMetrics.rowInset)
                    .padding(.vertical, PalMetrics.rowVerticalPadding)
                }
            }
            VStack(spacing: 10) {
                PillButton(String(localized: "Connect"), kind: .accent, size: .large, accessibilityIdentifier: "setupGuideConnect") {
                    model.connectSaved()
                }
                PillButton(String(localized: "Replace"), size: .large, accessibilityIdentifier: "setupGuideReplace") {
                    model.confirmsReplace = true
                }
            }
            .padding(.horizontal, PalMetrics.screenMargin)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
