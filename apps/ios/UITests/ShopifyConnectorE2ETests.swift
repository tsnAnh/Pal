import PalDesign
import XCTest

@MainActor
final class ShopifyConnectorE2ETests: ConnectAppsTestCase {
    private let script = "-hermes-test-shopify"

    func test1LightRefusesAnUnsecuredAddressThenConnectsABareStoreName() throws {
        try connectStore(appearance: .light)
    }

    func test2DarkRefusesAnUnsecuredAddressThenConnectsABareStoreName() throws {
        try connectStore(appearance: .dark)
    }

    private func connectStore(appearance: AppearanceMode) throws {
        let app = launchConnectApps(appearance: appearance, extraArguments: [script])
        waitForCatalog(app)
        search(app, "Shopify")
        let connect = action(app, "shopify")
        waitFor(connect, timeout: 30, "Shopify row action")
        XCTAssertEqual(connect.label, "Connect")
        connect.tap()

        let flow = element(app, id: "stepFlow")
        waitFor(flow, timeout: 15, "Shopify store address step")
        waitLabel(app.staticTexts["stepFlowStepTitle"], contains: "Enter your store address")
        let primary = app.buttons["stepFlowPrimary"]
        XCTAssertFalse(primary.isEnabled, "connect waits for an address")
        let field = element(app, id: "stepFlowField-address")
        waitFor(field, timeout: 15, "store address field")
        shot(app, "shopify-\(appearance.rawValue)-1-address")

        field.tap()
        field.typeText("http://acme.myshopify.com")
        XCTAssertTrue(primary.isEnabled)
        primary.tap()
        let refusal = element(app, id: "stepFlowStatusTitle")
        waitFor(refusal, timeout: 30, "refusal of the unsecured address")
        waitLabel(refusal, contains: "does not look right")
        waitLabel(element(app, id: "stepFlowStatusReason"), contains: "https://")
        shot(app, "shopify-\(appearance.rawValue)-2-refused")

        app.buttons["stepFlowStatusAction"].tap()
        waitFor(field, timeout: 15, "address field again")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        field.typeText("acme")
        primary.tap()

        let success = element(app, id: "stepFlowSuccess")
        waitFor(success, timeout: 60, "Shopify connected")
        waitLabel(app.staticTexts["Shopify is connected"], contains: "connected")
        shot(app, "shopify-\(appearance.rawValue)-3-connected")
    }
}
