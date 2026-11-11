import PalDesign
import XCTest

@MainActor
final class SettingsParityShots: SettingsE2ETestCase {
    private static let settleDelay: TimeInterval = 2.5
    private static let scrollOneOffsetPoints: CGFloat = 213

    private func darkSettings() -> XCUIApplication {
        let app = signedIn(arguments: ["-\(AppearanceStore.defaultsKey)", AppearanceMode.dark.rawValue])
        openSettings(app)
        return app
    }

    private func parityShot(_ referenceName: String) {
        Thread.sleep(forTimeInterval: Self.settleDelay)
        screenShot("parity-\(referenceName)")
    }

    private func drag(_ app: XCUIApplication, points: CGFloat) {
        let height = app.windows.firstMatch.frame.height
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8 - points / height))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    func test27Settings() throws {
        let app = darkSettings()
        waitFor(element(app, "settingsUsageRow"), timeout: 30, "usage row")
        Thread.sleep(forTimeInterval: 4)
        parityShot("27-settings")
        drag(app, points: Self.scrollOneOffsetPoints)
        parityShot("31-settings-scroll1")
        for _ in 0..<4 { app.swipeUp(velocity: .fast) }
        parityShot("36-settings-bottom")
    }

    func test28Account() throws {
        let app = darkSettings()
        openRow(app, "settingsAccountRow", screen: "accountScreen")
        parityShot("28-account")
    }

    func test29Usage() throws {
        let app = darkSettings()
        openRow(app, "settingsUsageRow", screen: "usageScreen")
        waitFor(element(app, "usageMeter-e2e-openai-codex/Weekly"), timeout: 45, "usage meters")
        parityShot("29-usage")
    }

    func test30Vault() throws {
        let app = darkSettings()
        openRow(app, "settingsVaultRow", screen: "vaultScreen")
        parityShot("30-vault")
    }

    func test32Permissions() throws {
        let app = darkSettings()
        openRow(app, "settingsPermissionsRow", screen: "permissionsScreen")
        waitFor(element(app, "permissionsAddRule-ask"), timeout: 20, "rules")
        parityShot("32-permissions")
    }

    func test33BotComputer() throws {
        let app = darkSettings()
        openRow(app, "settingsBotComputerRow", screen: "botComputerScreen")
        waitFor(element(app, "botComputerDisk"), timeout: 20, "disk")
        parityShot("33-settings-scroll2")
    }

    func test34Devices() throws {
        let app = darkSettings()
        openRow(app, "settingsDevicesRow", screen: "devicesScreen")
        waitFor(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "device-")).firstMatch, timeout: 30, "devices")
        parityShot("34-devices")
    }

    func test35Appearance() throws {
        let app = darkSettings()
        openRow(app, "settingsAppearanceRow", screen: "appearanceScreen")
        parityShot("35-appearance")
    }
}
