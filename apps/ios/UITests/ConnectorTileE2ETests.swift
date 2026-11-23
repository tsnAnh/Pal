import XCTest

@MainActor
final class ConnectorTileE2ETests: ConnectAppsTestCase {
    private static let tileLeadingScanPoints: CGFloat = 62
    private static let minimumWhiteRunPoints: CGFloat = 6
    private static let whiteChannel: UInt8 = 250

    func test1ACataloguedConnectorSitsOnAWhiteTileInDarkMode() throws {
        let app = launchConnectApps(appearance: .dark)
        waitForCatalog(app)
        search(app, "Slack")
        let row = app.descendants(matching: .any)["connectApp-connector:slack"]
        waitFor(row, timeout: 30, "Slack row")
        shot(app, "connector-tile-white-dark")
        let run = try longestWhiteRun(in: row.screenshot())
        XCTAssertGreaterThanOrEqual(run, Self.minimumWhiteRunPoints, "the connector tile stays white in dark mode")
    }

    func test2ACataloguedConnectorSitsOnAWhiteTileInLightMode() throws {
        let app = launchConnectApps(appearance: .light)
        waitForCatalog(app)
        search(app, "Slack")
        let row = app.descendants(matching: .any)["connectApp-connector:slack"]
        waitFor(row, timeout: 30, "Slack row")
        shot(app, "connector-tile-white-light")
        let run = try longestWhiteRun(in: row.screenshot())
        XCTAssertGreaterThanOrEqual(run, Self.minimumWhiteRunPoints, "the connector tile stays white in light mode")
    }

    private func longestWhiteRun(in screenshot: XCUIScreenshot) throws -> CGFloat {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let scale = CGFloat(image.width) / max(screenshot.image.size.width, 1)
        let width = Int(Self.tileLeadingScanPoints * scale)
        let y = image.height / 2
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: width * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: -(image.height - 1 - y), width: image.width, height: image.height))
        var longest = 0
        var current = 0
        for x in 0..<width {
            let isWhite = (0..<3).allSatisfy { pixels[x * 4 + $0] >= Self.whiteChannel }
            current = isWhite ? current + 1 : 0
            longest = max(longest, current)
        }
        return CGFloat(longest) / scale
    }
}
