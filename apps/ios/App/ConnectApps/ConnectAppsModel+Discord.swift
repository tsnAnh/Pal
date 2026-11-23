import Foundation
import PalConnect
import SwiftUI

struct DiscordFlowSession: Identifiable {
    let id = UUID()
    let app: ConnectApp
    let model: StepFlowModel
}

extension ConnectAppsModel {
    func presentsDiscordFlow(_ app: ConnectApp) -> Bool {
        guard case .catalog(let entry) = app.source, entry.method == .botTokenStdio,
              let engine = DiscordFlow.engine(resume: entry.setupProgress)
        else { return false }
        let flow = DiscordFlowRunner(service: service, entry: entry)
        let model = StepFlowModel(
            engine: engine, store: GatewayStepFlowProgressStore(service: service, device: .current, gatewaySaved: entry.setupProgress?.saved ?? []),
            runner: { step, values in try await flow.run(step, values: values) },
            classify: { flow.classify($0) }, prepare: { try await flow.prepare($0) }
        )
        model.recovery = { [weak model] failure in
            guard let model else { return }
            await DiscordFlow.recover(failure, in: model)
        }
        discordFlow = DiscordFlowSession(app: app, model: model)
        return true
    }

    func closeDiscordFlow() {
        discordFlow = nil
    }
}

struct DiscordFlowSheet: ViewModifier {
    @Bindable var model: ConnectAppsModel

    func body(content: Content) -> some View {
        content.macSheet(
            item: $model.discordFlow,
            onDismiss: { Task { await model.reload() } },
            size: .stepper,
            content: { session in
                StepFlowView(
                    model: session.model, title: "Discord", app: session.app,
                    savedNote: String(localized: "Saved on your Pal. Mac and iPhone show the same step."), close: { model.closeDiscordFlow() },
                    accessory: { _ in EmptyView() }
                )
            }
        )
    }
}
