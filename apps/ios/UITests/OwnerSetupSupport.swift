import XCTest

@MainActor
struct OwnerSetupDriver {
    let test: ConnectAppsTestCase
    let app: XCUIApplication

    func el(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    func reveal(_ id: String, timeout: TimeInterval = 15) -> XCUIElement {
        let target = el(id)
        test.waitFor(target, timeout: timeout, id)
        for _ in 0..<6 where !target.isHittable { app.swipeUp() }
        return target
    }

    func open(_ name: String, slug: String, action title: String = "Set up") -> XCUIElement {
        test.waitForCatalog(app)
        test.search(app, name)
        let button = test.action(app, slug)
        test.waitFor(button, timeout: 30, "\(name) action")
        XCTAssertEqual(button.label, title)
        button.hit()
        test.waitFor(el("ownerSetup"), timeout: 20, "owner setup")
        test.waitFor(el("stepFlow"), timeout: 30, "step flow")
        return button
    }

    func expectIntro(_ title: String, rows: Int? = nil) {
        let heading = el("stepFlowStepTitle")
        test.waitFor(heading, timeout: 20, "intro title")
        test.waitLabel(heading, equals: title, timeout: 20)
        test.waitFor(el("stepFlowIntro"), timeout: 10, "intro card")
        XCTAssertEqual(el("stepFlowPrimary").label, "Start")
        XCTAssertFalse(el("stepFlowBack").exists, "no way back from the intro")
        XCTAssertFalse(el("stepFlowSkip").exists, "nothing to skip on the intro")
        if let rows { test.waitLabel(el("stepFlowStepBody"), contains: "\(rows) short steps", timeout: 10) }
    }

    func expectStep(_ id: String, _ title: String, number: Int, of total: Int? = nil) {
        let heading = el("stepFlowStepTitle")
        test.waitFor(heading, timeout: 20, "step \(id)")
        test.waitLabel(heading, equals: title, timeout: 20)
        if el("stepFlowChecklist").exists {
            test.waitFor(el("stepFlowRow-\(id)"), timeout: 10, "checklist row \(id)")
            return
        }
        let position = el("stepFlowPosition")
        test.waitFor(position, timeout: 10, "position")
        if let total {
            test.waitLabel(position, equals: "Step \(number) of \(total)", timeout: 10)
        } else {
            test.waitLabel(position, contains: "Step \(number) of", timeout: 10)
        }
    }

    func primary(_ title: String) {
        let button = el("stepFlowPrimary")
        test.waitFor(button, timeout: 20, "primary \(title)")
        XCTAssertEqual(button.label, title)
        button.hit()
    }

    func expectOpened(_ prefix: String) {
        let probe = el("externalLinkProbe")
        test.waitUntil(30, "page \(prefix) handed to the system browser") { probe.label.hasPrefix(prefix) }
    }

    func expectCopy(_ index: Int, equals value: String) {
        let shown = el("stepFlowCopy-\(index)Value")
        test.waitFor(shown, timeout: 10, "copy value \(index)")
        XCTAssertEqual(shown.label, value, "the value is shown exactly")
        let button = reveal("stepFlowCopy-\(index)Button")
        button.hit()
        test.waitLabel(button, contains: "Copied", timeout: 10)
    }

    func enter(_ field: String, _ text: String) {
        let input = reveal("stepFlowField-\(field)")
        input.hit()
        input.typeText(text)
    }

    func clear(_ field: String, removing text: String) {
        let input = reveal("stepFlowField-\(field)")
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).hit()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
    }

    func expectHint(_ field: String, contains text: String) {
        let hint = el("stepFlowHint-\(field)")
        test.waitFor(hint, timeout: 10, "hint for \(field)")
        test.waitLabel(hint, contains: text, timeout: 10)
    }

    func expectValid(_ field: String) {
        test.waitLabel(el("stepFlowHint-\(field)"), equals: "Looks right", timeout: 10)
    }

    func expectPrimary(enabled: Bool, _ message: String) {
        let button = el("stepFlowPrimary")
        test.waitFor(button, timeout: 10, "primary")
        XCTAssertEqual(button.isEnabled, enabled, message)
    }

    func expectRejected(
        code: String, title: String, action actionTitle: String, reason: String? = nil, shot name: String
    ) {
        test.waitFor(el("stepFlowStatusBlock"), timeout: 20, "status block")
        test.waitLabel(el("stepFlowStatusTitle"), equals: title, timeout: 10)
        if let reason { test.waitLabel(el("stepFlowStatusReason"), equals: reason, timeout: 10) }
        XCTAssertEqual(el("stepFlowStatusAction").label, actionTitle)
        el("stepFlowStatusDetails").hit()
        test.waitFor(el("stepFlowStatusCopyDetails"), timeout: 10, "copy details")
        test.waitLabel(el("stepFlowStatusDetailsText"), contains: "code: \(code)", timeout: 10)
        test.shot(app, name)
        el("stepFlowStatusAction").hit()
        test.waitGone(el("stepFlowStatusBlock"), timeout: 10, "status block closes")
    }

    func expectWaiting(_ title: String) {
        test.waitFor(el("stepFlowWaiting"), timeout: 15, "waiting screen")
        test.waitLabel(el("stepFlowCalmTitle"), equals: title, timeout: 10)
        XCTAssertTrue(el("stepFlowCancel").exists, "waiting can be cancelled")
        XCTAssertFalse(el("stepFlowPrimary").exists, "no action while waiting")
    }

    func expectConnected(_ title: String) {
        test.waitFor(el("stepFlowSuccess"), timeout: 60, "success screen")
        test.waitLabel(el("stepFlowCalmTitle"), equals: title, timeout: 10)
        XCTAssertFalse(el("stepFlowBack").exists, "no way back from the end")
    }

    func finish(_ button: XCUIElement, reads label: String, exact: Bool = true) {
        primary("Done")
        test.waitGone(el("ownerSetup"), timeout: 30, "setup closes")
        if exact {
            test.waitLabel(button, equals: label, timeout: 45)
        } else {
            test.waitLabel(button, contains: label, timeout: 45)
        }
    }

    func close() {
        let close = el("stepFlowClose")
        test.waitFor(close, timeout: 10, "close")
        close.hit()
        test.waitGone(el("ownerSetup"), timeout: 20, "setup closes")
    }

    func returnFromBrowser() {
        let state = "state=scripted-state"
        #if os(macOS)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:27890/callback?code=fake-token-do-not-use&\(state)")!)
        request.setValue("localhost:27890", forHTTPHeaderField: "Host")
        let returned = test.expectation(description: "redirect delivered")
        URLSession.shared.dataTask(with: request) { _, _, _ in returned.fulfill() }.resume()
        test.wait(for: [returned], timeout: 15)
        #else
        expectStep("callback", "Paste the address your browser ended on", number: 5, of: 5)
        enter("callback", "http://localhost:27890/callback?code=fake-token-do-not-use&\(state)")
        expectValid("callback")
        primary("Check and save")
        #endif
    }
}
