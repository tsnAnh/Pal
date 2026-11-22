import PalConnect
import SwiftUI

struct T3CodeFlowSheet: View {
    let flow: AddressFlowItem
    let close: () -> Void

    var body: some View {
        StepFlowView(model: flow.model, title: T3CodeConnector.name, close: close, accessory: { _ in EmptyView() })
            .task(id: flow.model.engine.current.id) { await prefillAddress() }
    }

    private func prefillAddress() async {
        let engine = flow.model.engine
        guard engine.current.id == "address", engine.value(for: "address").isEmpty,
              let suggestion = await T3AddressSuggestion.current(),
              !Task.isCancelled, engine.current.id == "address", engine.value(for: "address").isEmpty
        else { return }
        flow.model.setValue(suggestion, for: "address")
    }
}

struct T3CodeSheet: ViewModifier {
    @Bindable var model: ConnectAppsModel

    func body(content: Content) -> some View {
        content.macSheet(item: $model.t3Flow, onDismiss: { Task { await model.reload() } }, size: .flow, content: { flow in
            T3CodeFlowSheet(flow: flow) { model.t3Flow = nil }
        })
    }
}
