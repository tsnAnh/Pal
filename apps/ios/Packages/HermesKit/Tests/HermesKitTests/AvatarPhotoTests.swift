import CoreGraphics
import Foundation
import HermesBotProfile
import HermesProtocol
import ImageIO
import Testing

@Suite("Avatar photo")
struct AvatarPhotoTests {
    private func encoded(width: Int, height: Int, type: String) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func dimensions(_ data: Data) throws -> (Int, Int, String) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height, CGImageSourceGetType(source) as String? ?? "")
    }

    @Test("a wide photo becomes a square 256 PNG")
    func squares() throws {
        let png = try AvatarPhoto.prepare(try encoded(width: 900, height: 400, type: "public.jpeg"))
        let (width, height, type) = try dimensions(png)
        #expect(width == AvatarPhoto.edge)
        #expect(height == AvatarPhoto.edge)
        #expect(type == "public.png")
        #expect(png.count <= AvatarPhoto.maximumUploadBytes)
    }

    @Test("non-image bytes and oversized sources are refused before any upload")
    func refuses() {
        #expect(throws: AvatarPhoto.Failure.unsupported) { try AvatarPhoto.prepare(Data("not an image".utf8)) }
        #expect(throws: AvatarPhoto.Failure.tooLarge) {
            try AvatarPhoto.prepare(Data(count: AvatarPhoto.maximumSourceBytes + 1))
        }
    }

    @Test("upload sends a data URL scoped to the profile and the avatar asset")
    func upload() async throws {
        let bots = ScriptedBots()
        bots.script("profiles.set_asset", ["ok": true, "asset": "avatar", "size": 3])
        try await BotProfileService(gateway: bots.gateway).setAvatarPhoto("a", png: Data([1, 2, 3]))
        let call = try #require(bots.calls(to: "profiles.set_asset").first)
        #expect(call.params["name"] == .string("a"))
        #expect(call.params["asset"] == .string("avatar"))
        #expect(call.params["data"] == .string("data:image/png;base64,AQID"))
    }

    @Test("an oversized upload is refused without a gateway call")
    func uploadTooLarge() async {
        let bots = ScriptedBots()
        await #expect(throws: BotsError.rejected(reason: "asset_too_large")) {
            try await BotProfileService(gateway: bots.gateway).setAvatarPhoto("a", png: Data(count: AvatarPhoto.maximumUploadBytes + 1))
        }
        #expect(bots.calls.isEmpty)
    }

    @Test("removing a photo clears the avatar asset")
    func clear() async throws {
        let bots = ScriptedBots()
        bots.script("profiles.set_asset", ["ok": true, "removed": true])
        try await BotProfileService(gateway: bots.gateway).clearAvatarPhoto("a")
        let call = try #require(bots.calls(to: "profiles.set_asset").first)
        #expect(call.params["clear"] == .bool(true))
        #expect(call.params["asset"] == .string("avatar"))
    }

    @Test("a photo look records the image kind and drops the legacy inline image")
    func photoLook() async throws {
        let bots = ScriptedBots()
        bots.script("profiles.list", profilesList(profileRow("a", meta: ["title": "A", "image": "data:image/png;base64,AA=="], revision: 3)))
        bots.script("profiles.configure", ["ok": true, "applied": ["ui_meta": true]])
        try await BotProfileService(gateway: bots.gateway).updateLook("a", shape: "boxy", colorHex: "#fff", photo: true)
        let call = try #require(bots.calls(to: "profiles.configure").first)
        #expect(call.params["ui_meta"] == ["hermes-bots": ["title": "A", "shape": "boxy", "color": "#fff", "custom": true, "imageKind": "photo"]])
    }
}
