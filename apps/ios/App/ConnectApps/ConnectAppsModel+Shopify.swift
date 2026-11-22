import Foundation
import PalConnect

extension ConnectAppsModel {
    func openShopify() {
        guard let engine = ShopifyFlow.engine() else { return }
        let model = StepFlowModel(
            engine: engine, runner: ShopifyFlow.runner(service: service), classify: { ShopifyFlow.classify($0) }
        )
        shopifyFlow = AddressFlowItem(app: catalog.apps.first(where: \.isShopify), model: model)
    }
}
