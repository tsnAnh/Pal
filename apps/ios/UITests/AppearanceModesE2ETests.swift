import HermesDesign
import SwiftUI
import XCTest

@MainActor
final class AppearanceModesE2ETests: E2ETestCase {
    private static let channelTolerance = 3
    private static let appearanceSwitchDelay: TimeInterval = 3

    private func canvasColor(of screenshot: XCUIScreenshot) throws -> RGB {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let x = 4
        let y = image.height * 62 / 100
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return RGB(hex: UInt32(pixel[0]) << 16 | UInt32(pixel[1]) << 8 | UInt32(pixel[2]))
    }

    private func assertClose(_ actual: RGB, _ expected: RGB, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let deltas = [
            abs(Int((actual.red * 255).rounded()) - Int((expected.red * 255).rounded())),
            abs(Int((actual.green * 255).rounded()) - Int((expected.green * 255).rounded())),
            abs(Int((actual.blue * 255).rounded()) - Int((expected.blue * 255).rounded())),
        ]
        XCTAssertLessThanOrEqual(
            deltas.max() ?? 0, Self.channelTolerance,
            "\(message): rendered \(actual.hexString), expected \(expected.hexString)", file: file, line: line
        )
    }

    private func renderedCanvas(mode: AppearanceMode) throws -> RGB {
        let app = launch(extraArguments: ["-\(AppearanceStore.defaultsKey)", mode.rawValue])
        signInIfNeeded(app)
        let anyBotRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-")).firstMatch
        waitFor(anyBotRow, timeout: 30, "roster rows")
        Thread.sleep(forTimeInterval: 1.5)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "appearance-\(mode.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = env.shotsDirectory {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("appearance-\(mode.rawValue).png"))
        }
        app.terminate()
        return try canvasColor(of: screenshot)
    }

    func test1ExplicitModesRenderTheirPalette() throws {
        let signIn = launch(resetCredentials: true)
        signInIfNeeded(signIn)
        signIn.terminate()

        let accent = try XCTUnwrap(RGB(hexString: try XCTUnwrap(BotAccent(name: "default", uiMeta: nil)).accentHex))
        let expectations: [(AppearanceMode, ColorScheme)] = [(.light, .light), (.dark, .dark), (.black, .dark), (.botColor, .dark)]
        var rendered: [AppearanceMode: RGB] = [:]
        for (mode, scheme) in expectations {
            let canvas = try renderedCanvas(mode: mode)
            assertClose(canvas, mode.palette(systemScheme: scheme, botAccent: accent).canvas, "\(mode.rawValue) canvas")
            rendered[mode] = canvas
        }
        XCTAssertEqual(Set(rendered.values.map(\.hex)).count, 4, "four explicit modes render four different canvases")
    }

    func test2FollowSystemRendersTheLightPaletteOnALightDevice() throws {
        XCUIDevice.shared.appearance = .light
        Thread.sleep(forTimeInterval: Self.appearanceSwitchDelay)
        assertClose(try renderedCanvas(mode: .followSystem), HermesPalette.derivedLight.canvas, "follow system on a light device")
    }
}
