import PalConnect
import SwiftUI

struct ShopifyFlowSheet: View {
    let flow: AddressFlowItem
    let close: () -> Void

    var body: some View {
        StepFlowView(model: flow.model, title: ShopifyConnector.name, close: close, accessory: { _ in EmptyView() })
    }
}

struct ShopifySheet: ViewModifier {
    @Bindable var model: ConnectAppsModel

    func body(content: Content) -> some View {
        content.macSheet(item: $model.shopifyFlow, onDismiss: { Task { await model.reload() } }, size: .flow, content: { flow in
            ShopifyFlowSheet(flow: flow) { model.shopifyFlow = nil }
        })
    }
}
