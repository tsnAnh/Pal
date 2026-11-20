import CoreGraphics
import ImageIO
import Testing
@testable import PalDesign

@Suite("A bot avatar renders to a PNG a notification can carry")
@MainActor
struct BotAvatarSnapshotTests {
    private static let blob = BotAvatarSpec(
        name: "memolly",
        uiMeta: [BotAvatarMeta.uiMetaKey: ["shape": "blobatar:memolly:round", "color": "#7a5cf0", "custom": true]],
        photo: nil
    )

    private func decode(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test("a known blobatar is a square PNG of the requested size with the bot in the middle")
    func knownSpec() throws {
        let data = try #require(BotAvatarSnapshot.pngData(for: Self.blob, pixels: 128))
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let image = try decode(data)
        #expect(image.width == 128 && image.height == 128)
        let alpha = try alphaPlane(of: image)
        #expect(alpha[0] == 0, "the corner stays transparent so the system's circle shows the blob")
        #expect(alpha[(image.height / 2) * image.width + image.width / 2] != 0)
    }

    private func alphaPlane(of image: CGImage) throws -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &rgba, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
    }

    @Test("the same spec renders the same bytes")
    func deterministic() throws {
        let first = try #require(BotAvatarSnapshot.pngData(for: Self.blob, pixels: 64))
        let second = try #require(BotAvatarSnapshot.pngData(for: Self.blob, pixels: 64))
        #expect(first == second)
    }

    @Test("a different colour renders a different picture")
    func differs() throws {
        let other = BotAvatarSpec(
            name: "memolly",
            uiMeta: [BotAvatarMeta.uiMetaKey: ["shape": "blobatar:memolly:round", "color": "#27a6a0", "custom": true]],
            photo: nil
        )
        let first = try #require(BotAvatarSnapshot.pngData(for: Self.blob, pixels: 64))
        let second = try #require(BotAvatarSnapshot.pngData(for: other, pixels: 64))
        #expect(first != second)
    }
}
