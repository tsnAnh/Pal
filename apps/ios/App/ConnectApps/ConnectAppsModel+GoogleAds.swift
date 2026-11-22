import Foundation
import PalConnect
import SwiftUI

struct GoogleAdsFlowSession: Identifiable {
    let id = UUID()
    let model: StepFlowModel
}

extension ConnectAppsModel {
    func openGoogleAds(_ app: ConnectApp) async {
        guard googleAdsFlow == nil, !busy.contains(app.id) else { return }
        busy.insert(app.id)
        defer { busy.remove(app.id) }
        let status = try? await service.googleAdsStatus()
        guard let engine = GoogleAdsFlow.engine(status: status) else { return }
        let runner = GoogleAdsFlowRunner(service: service)
        let flow = StepFlowModel(
            engine: engine, store: GatewayStepFlowProgressStore(service: service, device: .current),
            runner: { step, values in try await runner.run(step, values: values) }, classify: { runner.classify($0) }
        )
        flow.recovery = { [weak flow] failure in
            guard let flow else { return }
            await GoogleAdsFlow.recover(failure, in: flow)
        }
        googleAdsFlow = GoogleAdsFlowSession(model: flow)
    }

    func closeGoogleAdsFlow() {
        googleAdsFlow = nil
    }
}

struct GoogleAdsFlowSheet: ViewModifier {
    @Bindable var model: ConnectAppsModel

    func body(content: Content) -> some View {
        content.macSheet(
            item: $model.googleAdsFlow,
            onDismiss: { Task { await model.reload() } },
            size: .flow,
            content: { session in
                StepFlowView(model: session.model, title: GoogleAdsConnector.name, close: { model.closeGoogleAdsFlow() }, accessory: { _ in EmptyView() })
            }
        )
    }
}
