#if os(macOS)
import PalDesign
import XCTest

@MainActor
final class MacModalVisibleE2ETests: BotProfileTestCase {
    private static let windowWidth: CGFloat = 1280
    private static let tolerance: CGFloat = 2

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func resizeWindow(_ app: XCUIApplication, toWidth target: CGFloat) {
        let window = app.windows.firstMatch
        let delta = target - window.frame.width
        guard abs(delta) > Self.tolerance else { return }
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -1, dy: 0))
        edge.press(forDuration: 0.3, thenDragTo: edge.withOffset(CGVector(dx: delta, dy: 0)))
        waitUntil(5, "window reaches \(target) pt") { abs(window.frame.width - target) <= 8 }
    }

    private struct PanelCase {
        let key: String
        let panel: String
        let label: String?
        let inside: String
    }

    private func assertPanelVisible(_ app: XCUIApplication, _ identifier: String, label: String?, inside: String) {
        let panel = any(app, identifier)
        waitFor(panel, timeout: 30, "\(identifier) on screen")
        let window = app.windows.firstMatch.frame
        let frame = panel.frame
        let expected = MacModalSizing.frame(window: window.size)
        XCTAssertGreaterThan(frame.width * frame.height, 0, "\(identifier) has a non-zero frame")
        XCTAssertTrue(window.insetBy(dx: -Self.tolerance, dy: -Self.tolerance).contains(frame), "\(identifier) \(frame) sits inside the window \(window)")
        XCTAssertLessThanOrEqual(frame.width, expected.width + Self.tolerance, "\(identifier) is at most 90% of the window wide")
        waitFor(any(app, inside), timeout: 30, "\(inside) inside \(identifier)")
        if let label {
            waitFor(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch, timeout: 30, "\(label) in the accessibility tree")
        }
    }

    func test1ConnectAppsOpensAsAVisiblePanelInsideA1280Window() throws {
        let app = signedInApp(extraArguments: ["-hermes-open-connect-apps"])
        resizeWindow(app, toWidth: Self.windowWidth)
        assertPanelVisible(app, "connectAppsPanel", label: "Connect Apps", inside: "connectAppsSearch")
        let ninety = MacModalSizing.frame(window: app.windows.firstMatch.frame.size).width
        XCTAssertGreaterThan(any(app, "connectAppsPanel").frame.width, ninety - Self.tolerance - 1, "Connect Apps takes 90% of the window")
        app.typeKey(.escape, modifierFlags: [])
        waitGone(any(app, "connectAppsPanel"), timeout: 10, "Connect Apps closes")
    }

    func test2SettingsShortcutsAndSearchOpenAsVisiblePanels() throws {
        let app = signedInApp()
        resizeWindow(app, toWidth: Self.windowWidth)
        let cases = [
            PanelCase(key: ",", panel: "settingsSheetPanel", label: "General", inside: "settingsSheet"),
            PanelCase(key: "/", panel: "shortcutsSheet", label: "Keyboard shortcuts", inside: "shortcut-compactSidebar"),
            PanelCase(key: "k", panel: "searchPanel", label: nil, inside: "searchField"),
        ]
        for entry in cases {
            app.typeKey(entry.key, modifierFlags: .command)
            assertPanelVisible(app, entry.panel, label: entry.label, inside: entry.inside)
            app.typeKey(.escape, modifierFlags: [])
            waitGone(any(app, entry.panel), timeout: 10, "\(entry.panel) closes")
        }
    }
}
#endif
