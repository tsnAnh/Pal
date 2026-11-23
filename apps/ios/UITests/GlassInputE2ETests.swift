import XCTest

@MainActor
final class GlassInputE2ETests: ConnectAppsTestCase {
    private var platform: String {
        #if os(macOS)
        "mac"
        #else
        "ios"
        #endif
    }

    func test1SkillsCatalogSearchIsOneGlassSurface() throws {
        let app = launchConnectApps()
        waitForCatalog(app)
        let entry = element(app, id: "connectAppsSection-skillsCatalog")
        for _ in 0..<20 where !(entry.exists && entry.isHittable) { app.swipeUp() }
        waitFor(entry, timeout: 30, "Skills catalog entry")
        entry.hit()
        let field = element(app, id: "skillsSearch")
        waitFor(field, timeout: 30, "skills search field")
        typeIntoField(app, field, "calendar helper", screen: "skills-search")
    }

    func test2ConnectAppsSearchIsOneGlassSurface() throws {
        let app = launchConnectApps()
        waitForCatalog(app)
        let field = element(app, id: "connectAppsSearch")
        waitFor(field, timeout: 20, "connect apps search field")
        typeIntoField(app, field, "calendar helper", screen: "connect-apps-search", reveal: { app.swipeDown() })
    }

    func test3CustomConnectorNameFieldTakesTypedText() throws {
        let app = openCustomConnector()
        let field = element(app, id: "customConnectorNameField")
        typeIntoField(app, field, "Example connector", screen: "custom-connector-name", reveal: { app.swipeUp() })
    }

    func test4CustomConnectorSecretFieldTakesTypedText() throws {
        let app = openCustomConnector()
        let field = element(app, id: "customConnectorHeaderValue-0")
        let secret = "not-a-real-secret-value"
        waitFor(field, timeout: 10, "header value field")
        for _ in 0..<6 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.exists, "secret field exists")
        XCTAssertTrue(field.isHittable, "secret field is hittable")
        field.hit()
        field.typeText(secret)
        XCTAssertTrue(field.exists, "secret field survives typing")
        XCTAssertFalse(app.debugDescription.contains(secret), "the secret is not in the hierarchy while typing")
        shot(app, "glass-input-custom-connector-secret-\(platform)")
    }

    private func openCustomConnector() -> XCUIApplication {
        let app = launchConnectApps()
        waitForCatalog(app)
        search(app, "zzzz no such app")
        let add = app.buttons["addCustomConnectorButton"]
        waitFor(add, timeout: 20, "add custom connector button")
        add.hit()
        waitFor(element(app, id: "customConnectorNameField"), timeout: 20, "custom connector form opens")
        return app
    }

    private func typeIntoField(
        _ app: XCUIApplication, _ field: XCUIElement, _ text: String, screen: String,
        reveal: () -> Void = {}, file: StaticString = #filePath, line: UInt = #line
    ) {
        for _ in 0..<20 where !field.isHittable { reveal() }
        XCTAssertTrue(field.exists, "\(screen) field exists", file: file, line: line)
        XCTAssertTrue(field.isHittable, "\(screen) field is hittable", file: file, line: line)
        field.hit()
        field.typeText(text)
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [typed], timeout: 10), .completed, "\(screen) field never read '\(text)'", file: file, line: line)
        shot(app, "glass-input-\(screen)-\(platform)")
    }
}
