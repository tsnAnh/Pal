import CoreGraphics
import SwiftUI
import Testing
@testable import PalDesign

private let side = 100
private let body = (r: 62, g: 142, b: 247)

@MainActor
private func render(_ view: some View, scale: CGFloat = 1) throws -> PixelBuffer {
    let renderer = ImageRenderer(content: view.frame(width: CGFloat(side), height: CGFloat(side)))
    renderer.scale = scale
    let image = try #require(renderer.cgImage)
    return try PixelBuffer(image: image, side: image.width)
}

private func pixel(_ buffer: PixelBuffer, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let index = (y * buffer.side + x) * 4
    return (Int(buffer.rgba[index]), Int(buffer.rgba[index + 1]), Int(buffer.rgba[index + 2]))
}

private func near(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int), within tolerance: Int = 3) -> Bool {
    abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
}

private func spec(_ shape: String = "circle", color: String = "#3e8ef7") -> BotAvatarSpec {
    BotAvatarSpec(name: "Atlas", meta: BotAvatarMeta(shape: shape, color: color, custom: true))
}

@Suite("Rendered solid avatars", .serialized)
@MainActor
struct SolidRenderTests {
    @Test("the body is one flat colour with no seams, shading or gloss", arguments: ["circle", "blobatar:k7q2m9x0:round", "hexagon"])
    func flatBody(shape: String) throws {
        let buffer = try render(BotAvatarView(spec: spec(shape), size: CGFloat(side), animated: false))
        let avatar = solid(shape)
        let origin = avatar.projection(size: CGFloat(side), inset: 0).origin
        let radius = avatar.projection(size: CGFloat(side), inset: 0).unit * 0.9
        var inside = 0
        var bodyColoured = 0
        var shaded = 0
        for y in 0..<side {
            for x in 0..<side where hypot(Double(x) + 0.5 - origin.x, Double(y) + 0.5 - origin.y) < radius {
                inside += 1
                let colour = pixel(buffer, x, y)
                if near(colour, body) { bodyColoured += 1 } else if colour.r > body.r + 4 { shaded += 1 }
            }
        }
        #expect(Double(bodyColoured) / Double(inside) > 0.85, "\(shape) body colour covers \(Double(bodyColoured) / Double(inside))")
        #expect(Double(shaded) / Double(inside) < 0.01, "\(shape) has \(shaded) lighter body pixels")
    }

    @Test("the eyes are drawn in the eye ink on the body")
    func eyesAreInked() throws {
        let ink = try #require(AvatarColor(css: "#ff0000"))
        let buffer = try render(BotAvatarView(spec: spec(), size: CGFloat(side), animated: false, eyeInk: ink))
        var red = 0
        for y in 0..<side { for x in 0..<side where near(pixel(buffer, x, y), (255, 0, 0), within: 12) { red += 1 } }
        #expect(red > 150)
    }

    @Test("the outline ring surrounds the solid and leaves the body alone")
    func outlineRing() throws {
        let ring = AvatarOutline(gap: 2, thickness: 3, color: Color(red: 1, green: 0, blue: 0))
        let buffer = try render(BotAvatarView(spec: spec(), size: 60, animated: false, outline: ring).frame(width: 100, height: 100))
        let origin = CGPoint(x: Double(side) / 2, y: Double(side) / 2)
        var ringPixels = 0
        var bodyAtCentre = 0
        for y in 0..<side {
            for x in 0..<side {
                let colour = pixel(buffer, x, y)
                if near(colour, (255, 0, 0), within: 10) {
                    ringPixels += 1
                    #expect(hypot(Double(x) - origin.x, Double(y) - origin.y) > 20, "ring over the body at \(x),\(y)")
                }
            }
        }
        if near(pixel(buffer, 40, 60), body) { bodyAtCentre += 1 }
        #expect(ringPixels > 200, "ring pixels \(ringPixels)")
        #expect(bodyAtCentre == 1, "centre \(pixel(buffer, 40, 60))")
    }

    @Test("a faded pose fades the body as a whole")
    func fades() throws {
        let faded = AvatarPose.rest.with { $0.opacity = 0.5 }
        let content = AvatarContent(spec())
        let buffer = try render(AvatarFrame(content: content, pose: faded, size: CGFloat(side)))
        let colour = pixel(buffer, 22, 60)
        #expect(colour.r > 62 + 60 && colour.r < 255 - 40 && colour.g > 142 && colour.b > 247 - 60)
    }

    @Test("hovering turns the avatar toward the pointer")
    func hoverTurns() throws {
        let content = AvatarContent(spec())
        let centred = try render(AvatarFrame(content: content, pose: .rest, size: CGFloat(side), look: AvatarLook(amount: 1, x: 0, y: 0)))
        let right = try render(AvatarFrame(content: content, pose: .rest, size: CGFloat(side), look: AvatarLook(amount: 1, x: 1, y: 0)))
        func eyeCentroidX(_ buffer: PixelBuffer) -> Double {
            var sum = 0.0
            var count = 0.0
            for y in 0..<side { for x in 0..<side where pixel(buffer, x, y).r < 40 { sum += Double(x); count += 1 } }
            return count > 0 ? sum / count : -1
        }
        #expect(eyeCentroidX(right) > eyeCentroidX(centred) + 4)
    }
}
