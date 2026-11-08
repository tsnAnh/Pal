import SwiftUI
import Testing
@testable import HermesDesign

private func spec(color: String, shape: String) -> BotAvatarSpec {
    BotAvatarSpec(name: "tone", uiMeta: [BotAvatarMeta.uiMetaKey: ["shape": shape, "color": color, "custom": true]], photo: nil)
}

private func rig(color: String, shape: String, scheme: ColorScheme) throws -> AvatarRig {
    guard case .rig(let rig) = AvatarContent(spec(color: color, shape: shape)).toned(for: scheme) else {
        throw ToneError.notARig
    }
    return rig
}

private enum ToneError: Error {
    case notARig
}

private func css(_ color: AvatarColor?) -> String? {
    color.map { String(format: "#%02x%02x%02x", Int($0.red), Int($0.green), Int($0.blue)) }
}

private let shapes = ["squircle", "cloud", "blob-1-organic", "sigil-7"]

@Suite("A white avatar turns dark on a light screen")
@MainActor
struct AvatarToneTests {
    @Test("body and strokes paint near black and eyes paint light", arguments: shapes)
    func whiteAvatarOnLightScreen(shape: String) throws {
        let toned = try rig(color: "#ffffff", shape: shape, scheme: .light)
        let bodyPaints = toned.body.flatMap { [css($0.fill), css($0.stroke?.color)] }.compactMap { $0 }
        #expect(!bodyPaints.isEmpty)
        #expect(bodyPaints.allSatisfy { $0 == "#1b1b1b" })
        let eyes = css(toned.eyes.fill)
        #expect(eyes == (shape.hasPrefix("sigil") ? "#1b1b1b" : "#f3f4fd"))
        #expect(toned.dots.compactMap { css($0.fill) }.allSatisfy { $0 == "#1b1b1b" })
    }

    @Test("the same avatar is untouched on a dark screen", arguments: shapes)
    func whiteAvatarOnDarkScreen(shape: String) throws {
        let original = try rig(color: "#ffffff", shape: shape, scheme: .dark)
        let reference = AvatarContent(spec(color: "#ffffff", shape: shape))
        guard case .rig(let base) = reference else { throw ToneError.notARig }
        #expect(original.body.map { css($0.fill) } == base.body.map { css($0.fill) })
        #expect(css(original.body.first?.fill ?? original.body.first?.stroke?.color) == "#ffffff")
        #expect(css(original.eyes.fill) == css(base.eyes.fill))
        #expect(css(original.eyes.fill) == (shape.hasPrefix("sigil") ? "#ffffff" : "#1b1b1b"))
    }

    @Test("a coloured avatar is untouched in both schemes", arguments: shapes, [ColorScheme.light, .dark])
    func colouredAvatar(shape: String, scheme: ColorScheme) throws {
        let toned = try rig(color: "#8b5cf6", shape: shape, scheme: scheme)
        #expect(css(toned.body.first?.fill ?? toned.body.first?.stroke?.color) == "#8b5cf6")
        #expect(toned.dots.compactMap { css($0.fill) }.allSatisfy { $0 == "#8b5cf6" })
    }

    @Test("the white cut-off sits at luminance 230", arguments: [
        ("#e5e5e5", false), ("#e7e7e7", true), ("#ffffff", true), ("#f0f0f0", true), ("#ffdddd", false), ("#8b5cf6", false),
    ])
    func boundary(color: String, isWhite: Bool) throws {
        #expect(try #require(AvatarColor(css: color)).isWhite == isWhite)
        let toned = try rig(color: color, shape: "squircle", scheme: .light)
        #expect((css(toned.body.first?.fill) == "#1b1b1b") == isWhite)
    }

    @Test("a photo avatar keeps its picture on a light screen")
    func photoUnchanged() throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        let photo = BotAvatarSpec.photo(PhotoAvatar(data: png, fallback: .classic(ClassicAvatar(shape: .squircle, color: .primary))))
        guard case .photo = AvatarContent(photo).toned(for: .light) else {
            Issue.record("expected a photo")
            return
        }
    }

    @Test("rendered on a white page, a white avatar fills dark only on a light screen")
    func rendered() throws {
        let white = spec(color: "#ffffff", shape: "squircle")
        func darkPixels(_ scheme: ColorScheme) throws -> Int {
            let renderer = ImageRenderer(
                content: BotAvatarView(spec: white, size: 100, animated: false).environment(\.colorScheme, scheme)
            )
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let buffer = try PixelBuffer(image: image, side: image.width)
            return stride(from: 0, to: buffer.rgba.count, by: 4).filter { buffer.rgba[$0] < 60 && buffer.rgba[$0 + 1] < 60 }.count
        }
        let onLight = try darkPixels(.light)
        let onDark = try darkPixels(.dark)
        #expect(onLight > 2000)
        #expect(onDark * 4 < onLight)
    }
}
