#if os(macOS)
import PalDesign
import XCTest

@MainActor
final class MacModalVisibleE2ETests: BotProfileTestCase {
    private static let windowWidth: CGFloat = 1280

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
        let size: MacModalSize
    }

    private func assertPanelVisible(_ app: XCUIApplication, _ identifier: String, size: MacModalSize, label: String?, inside: String) {
        let panel = any(app, identifier)
        waitFor(panel, timeout: 30, "\(identifier) on screen")
        let window = app.windows.firstMatch.frame
        let frame = panel.frame
        XCTAssertGreaterThan(frame.width * frame.height, 0, "\(identifier) has a non-zero frame")
        XCTAssertTrue(window.insetBy(dx: -Self.tolerance, dy: -Self.tolerance).contains(frame), "\(identifier) \(frame) sits inside the window \(window)")
        assertSizeClass(size, panel, identifier, window: window)
        waitFor(any(app, inside), timeout: 30, "\(inside) inside \(identifier)")
        if let label {
            waitFor(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch, timeout: 30, "\(label) in the accessibility tree")
        }
    }

    func test1ConnectAppsOpensAsAVisiblePanelInsideA1280Window() throws {
        let app = signedInApp()
        resizeWindow(app, toWidth: Self.windowWidth)
        app.typeKey("m", modifierFlags: [.command, .shift])
        assertPanelVisible(app, "connectAppsPanel", size: .full, label: "Connect Apps", inside: "connectAppsSearch")
        let expected = MacModalSizing.frame(window: app.windows.firstMatch.frame.size).width
        XCTAssertGreaterThan(any(app, "connectAppsPanel").frame.width, expected - Self.tolerance - 1, "Connect Apps takes the shared panel width")
        shot(app, "mac-size-full-connect-apps")
        app.typeKey(.escape, modifierFlags: [])
        waitGone(any(app, "connectAppsPanel"), timeout: 10, "Connect Apps closes")
    }

    func test2SettingsShortcutsAndSearchOpenAsVisiblePanels() throws {
        let app = signedInApp()
        let cases = [
            PanelCase(key: ",", panel: "settingsSheetPanel", label: nil, inside: "settingsSheet", size: .full),
            PanelCase(key: "/", panel: "shortcutsSheet", label: "Keyboard shortcuts", inside: "shortcut-compactSidebar", size: .wide),
            PanelCase(key: "k", panel: "searchPanel", label: nil, inside: "searchField", size: .palette),
        ]
        for width in [Self.windowWidth, MacLayoutMetrics.windowMin] {
            resizeWindow(app, toWidth: width)
            for entry in cases {
                app.typeKey(entry.key, modifierFlags: .command)
                assertPanelVisible(app, entry.panel, size: entry.size, label: entry.label, inside: entry.inside)
                if width == Self.windowWidth { shot(app, "mac-size-\(entry.size)-\(entry.panel)") }
                app.typeKey(.escape, modifierFlags: [])
                waitGone(any(app, entry.panel), timeout: 10, "\(entry.panel) closes")
            }
        }
    }

    func test3CreateBotIsAFormAndRenameIsCompact() throws {
        let app = signedInApp()
        resizeWindow(app, toWidth: Self.windowWidth)
        let window = app.windows.firstMatch.frame
        app.typeKey("n", modifierFlags: .command)
        let create = any(app, "createBotSheet")
        waitFor(create, timeout: 15, "create bot modal")
        waitFor(any(app, "botNameField"), timeout: 10, "name field")
        assertSizeClass(.form, create, "createBotSheet", window: window)
        shot(app, "mac-size-form-create-bot")
        app.buttons["createBotCancel"].hit()
        waitGone(create, timeout: 10, "create bot closes")

        let row = app.buttons["botRow-bot-alpha"]
        waitFor(row, timeout: 20, "bot row")
        row.rightClick()
        let rename = app.menuItems["renameBotAction"]
        waitFor(rename, timeout: 10, "rename in the context menu")
        rename.hit()
        let panel = any(app, "renameBotSheet")
        waitFor(panel, timeout: 10, "rename panel")
        waitFor(any(app, "renameBotField"), timeout: 10, "rename field")
        assertSizeClass(.compact, panel, "renameBotSheet", window: window)
        XCTAssertLessThan(panel.frame.height, MacModalSize.compact.frame(in: window.size).maxHeight / 2, "compact hugs a short form")
        shot(app, "mac-size-compact-rename-bot")
        app.buttons["renameBotCancel"].hit()
        waitGone(panel, timeout: 10, "rename closes")
    }

    func test4SheetsTakeTheirClassFromTheCallSite() throws {
        let app = signedInApp()
        resizeWindow(app, toWidth: Self.windowWidth)
        let window = app.windows.firstMatch.frame
        app.typeKey(",", modifierFlags: .command)
        waitFor(any(app, "settingsSheet"), timeout: 15, "settings modal")
        let vault = app.buttons["macSettingsSection-vault"]
        waitFor(vault, timeout: 10, "vault section")
        vault.hit()
        let add = app.buttons["vaultAddButton"]
        waitFor(add, timeout: 10, "new item button")
        add.hit()
        let sheet = any(app, "macSheet")
        waitFor(sheet, timeout: 10, "vault add sheet")
        waitFor(any(app, "vaultAddSheet"), timeout: 10, "vault add content")
        Thread.sleep(forTimeInterval: 1)
        shot(app, "mac-size-form-vault-add")
        assertSizeClass(.form, sheet, "vault add sheet", window: window)
        app.typeKey(.escape, modifierFlags: [])
        waitGone(sheet, timeout: 10, "vault add closes")
    }
}
#endif
