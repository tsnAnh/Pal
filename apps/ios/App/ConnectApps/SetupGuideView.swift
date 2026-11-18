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
        .alert(String(localized: "Let the bot post?"), isPresented: Binding(get: { model.confirmsWrite }, set: { model.confirmsWrite = $0 })) {
            Button(String(localized: "Allow posting"), role: .destructive) { model.confirmWrite() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("The bot can post, react and delete messages as itself in the servers you picked.")
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
        case .problem(let status):
            StatusBlock(status: status, identifierPrefix: "setupGuide") { perform(after: status) }
                .frame(maxHeight: .infinity)
        }
    }

    private func perform(after status: SetupStatus) {
        if status.kind == .forbidden {
            dismiss()
        } else {
            Task { await model.retry() }
        }
    }
}
