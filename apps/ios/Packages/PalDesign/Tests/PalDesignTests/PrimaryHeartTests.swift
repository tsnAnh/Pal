import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import PalDesign

@Suite("The primary bot is the 🩵 heart", .serialized)
@MainActor
struct PrimaryHeartTests {
    private static let emoji = (red: 0x93, green: 0xDC, blue: 0xF7)

    @Test("every spelling of the primary name resolves to the heart in the emoji colour with black eyes", arguments: ["default", "Default", " DEFAULT "])
    func resolves(name: String) throws {
        guard case .shape(.blob(let blob)) = BotAvatarSpec(name: name, meta: BotAvatarMeta()) else {
            Issue.record("\(name.debugDescription) should be a blob")
            return
        }
        #expect(blob.kind == .heart)
        #expect(blob.headFillCSS == "#93dcf7")
        let rig = AvatarContent.rig(.blob(blob))
        #expect(AvatarSolid(rig).eyeFill.css == "#000000")
    }

    @Test("the body keeps the exact emoji colour in light and dark", arguments: [ColorScheme.light, .dark])
    func renderedColour(scheme: ColorScheme) throws {
        let spec = BotAvatarSpec(name: "default", meta: BotAvatarMeta())
        let side = 96
        let renderer = ImageRenderer(
            content: AvatarFrame(content: AvatarContent(spec).toned(for: scheme), pose: .facing, size: CGFloat(side))
                .frame(width: CGFloat(side), height: CGFloat(side))
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let pixels = try PixelBuffer(image: image, side: side)
        let offset = (side * 62 + side / 2) * 4
        #expect(Int(pixels.rgba[offset]) == Self.emoji.red)
        #expect(Int(pixels.rgba[offset + 1]) == Self.emoji.green)
        #expect(Int(pixels.rgba[offset + 2]) == Self.emoji.blue)
    }

    @Test("the heart is a catalog shape any bot can pick")
    func pickable() {
        #expect(BotLookCatalog.shapes.contains(.heart))
        let shape = BotLookCatalog.shapeString(seed: "pal", kind: .heart)
        let picked = BotAvatarSpec(name: "pal", meta: BotAvatarMeta(shape: shape, color: "#f58a06", custom: true))
        guard case .shape(.blob(let blob)) = picked else {
            Issue.record("a picked heart is a blob")
            return
        }
        #expect(blob.kind == .heart)
        #expect(blob.headFillCSS == "#f58a06")
        #expect(BotLookCatalog.displayName(of: .heart) == "Heart")
    }
}
