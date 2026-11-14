#if os(iOS)
import XCTest

@MainActor
final class ModelProvidersE2ETests: E2ETestCase {
    private static let groups = ["connected", "available", "onHost"]
    private static let deepseekKey = "sk-test-deepseek-canary-0001"
    private static let anthropicToken = "sk-ant-oat01-fakecanary-0001"

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func openProviders() -> XCUIApplication {
        let app = launch(extraArguments: ["-hermes-reset-preferences"])
        signInIfNeeded(app)
        let avatar = app.buttons["userAvatarButton"]
        waitFor(avatar, timeout: 30, "avatar button")
        avatar.tap()
        waitFor(element(app, "settingsSheet"), timeout: 15, "settings sheet")
        let row = element(app, "settingsModelProvidersRow")
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        waitFor(row, timeout: 5, "Model providers row")
        row.tap()
        waitFor(element(app, "modelProvidersScreen"), timeout: 15, "Model providers screen")
        waitFor(element(app, "modelProviders-connected"), timeout: 30, "Connected caption")
        waitFor(element(app, "modelProviders-available"), timeout: 10, "Add a provider caption")
        return app
    }

    private func search(_ app: XCUIApplication, _ text: String) {
        let field = element(app, "modelProvidersSearch")
        waitFor(field, timeout: 10, "search field")
        field.tap()
        field.typeText(text)
    }

    private func clearSearch(_ app: XCUIApplication) {
        let field = element(app, "modelProvidersSearch")
        guard let current = field.value as? String, !current.isEmpty else { return }
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }

    private func stateText(_ app: XCUIApplication, _ id: String) -> String {
        let row = element(app, "modelProvider-\(id)-state")
        return "\(row.label) \(row.value as? String ?? "")"
    }

    private func assertRow(_ app: XCUIApplication, _ id: String, in group: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = element(app, "modelProvider-\(id)-state")
        waitFor(row, timeout: 20, "\(id) row", file: file, line: line)
        let index = Self.groups.firstIndex(of: group)!
        let caption = element(app, "modelProviders-\(group)")
        XCTAssertTrue(caption.exists, "\(group) caption is shown", file: file, line: line)
        XCTAssertGreaterThan(row.frame.minY, caption.frame.minY, "\(id) sits below the \(group) caption", file: file, line: line)
        for next in Self.groups[(index + 1)...] {
            let nextCaption = element(app, "modelProviders-\(next)")
            if nextCaption.exists {
                XCTAssertLessThan(row.frame.minY, nextCaption.frame.minY, "\(id) sits above the \(next) caption", file: file, line: line)
                break
            }
        }
        let card = element(app, "modelProvidersCard-\(group)")
        if card.exists {
            XCTAssertTrue(card.frame.insetBy(dx: -1, dy: -1).contains(row.frame), "\(id) is inside the \(group) card", file: file, line: line)
        }
    }

    private func waitForRow(_ app: XCUIApplication, _ id: String, in group: String, subtitle: String? = nil) {
        waitUntil(30, "\(id) moves into \(group)") {
            let row = element(app, "modelProvider-\(id)-state")
            let caption = element(app, "modelProviders-\(group)")
            guard row.exists, caption.exists, row.frame.minY > caption.frame.minY else { return false }
            let later = Self.groups.drop { $0 != group }.dropFirst().map { element(app, "modelProviders-\($0)") }.first(where: \.exists)
            if let later, row.frame.minY > later.frame.minY { return false }
            if let subtitle { return stateText(app, id).contains(subtitle) }
            return true
        }
    }

    private func submitSecret(_ app: XCUIApplication, _ secret: String) {
        let field = app.secureTextFields["service-signin-key-field"]
        waitFor(field, timeout: 20, "masked key field")
        field.tap()
        field.typeText(secret)
        let submit = element(app, "service-signin-key-save-button")
        waitFor(submit, timeout: 10, "submit button")
        XCTAssertTrue(submit.isEnabled, "submit is enabled once a value is typed")
        submit.tap()
    }

    private func waitUntil(_ timeout: TimeInterval, _ message: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail(message, file: file, line: line)
    }

    func test1GroupsAndSearch() throws {
        let app = openProviders()
        shot(app, "providers-1-before-search")
        XCTAssertLessThan(
            element(app, "modelProviders-connected").frame.minY, element(app, "modelProviders-available").frame.minY,
            "Connected is listed above Add a provider")
        search(app, "deeps")
        waitFor(element(app, "modelProvider-deepseek-state"), timeout: 10, "DeepSeek row")
        XCTAssertFalse(element(app, "modelProvider-openrouter-state").exists, "OpenRouter is filtered out")
        shot(app, "providers-1-searching")
        clearSearch(app)
        waitFor(element(app, "modelProvider-openrouter-state"), timeout: 10, "OpenRouter returns after clearing")
        shot(app, "providers-1-after-search")
    }

    func test2ApiKeyMovesToConnectedAndRemoveMovesBack() throws {
        let app = openProviders()
        search(app, "deeps")
        assertRow(app, "deepseek", in: "available")
        shot(app, "providers-2-before-add")
        let action = element(app, "modelProvider-deepseek-action")
        waitFor(action, timeout: 10, "DeepSeek action")
        action.tap()
        waitFor(element(app, "service-signin-dialog"), timeout: 20, "sign-in dialog")
        shot(app, "providers-2-dialog")
        submitSecret(app, Self.deepseekKey)
        waitGone(element(app, "service-signin-dialog"), timeout: 30, "dialog closes after saving")
        shot(app, "providers-2-after-save")
        waitForRow(app, "deepseek", in: "connected", subtitle: "Key saved.")
        assertRow(app, "deepseek", in: "connected")
        XCTAssertTrue(stateText(app, "deepseek").contains("Key saved."), stateText(app, "deepseek"))
        XCTAssertFalse(app.staticTexts[Self.deepseekKey].exists, "the key is never shown")
        shot(app, "providers-2-connected")

        let remove = element(app, "modelProvider-deepseek-remove")
        waitFor(remove, timeout: 10, "Remove row")
        remove.tap()
        let confirm = app.buttons.matching(identifier: "modelProviderRemoveConfirm").firstMatch
        waitFor(confirm, timeout: 10, "remove confirmation")
        shot(app, "providers-2-confirm")
        confirm.tap()
        waitGone(element(app, "modelProvider-deepseek-remove"), timeout: 30, "Remove row disappears")
        waitForRow(app, "deepseek", in: "available")
        assertRow(app, "deepseek", in: "available")
        waitFor(element(app, "modelProvider-deepseek-action"), timeout: 10, "Add action returns")
        shot(app, "providers-2-removed")
    }

    func test3AnthropicSetupTokenIsAccepted() throws {
        let app = openProviders()
        search(app, "anthropic")
        assertRow(app, "anthropic", in: "available")
        let action = element(app, "modelProvider-anthropic-action")
        waitFor(action, timeout: 10, "Anthropic action")
        shot(app, "providers-3-before-add")
        action.tap()
        waitFor(element(app, "service-signin-dialog"), timeout: 20, "sign-in dialog")
        waitFor(element(app, "service-signin-setup-token-help"), timeout: 10, "setup token help")
        waitFor(element(app, "service-signin-copy-command-button"), timeout: 10, "Copy Command button")
        XCTAssertTrue(element(app, "service-signin-dialog").staticTexts["API key or setup token"].exists
            || app.secureTextFields["service-signin-key-field"].label == "API key or setup token",
            "the field is labelled for keys and setup tokens")
        shot(app, "providers-3-dialog")
        submitSecret(app, Self.anthropicToken)
        waitGone(element(app, "service-signin-dialog"), timeout: 30, "dialog closes after saving")
        shot(app, "providers-3-after-save")
        waitForRow(app, "anthropic", in: "connected", subtitle: "Saved.")
        assertRow(app, "anthropic", in: "connected")
        XCTAssertTrue(stateText(app, "anthropic").contains("Saved."), stateText(app, "anthropic"))
        shot(app, "providers-3-connected")
    }
}
#endif
