import CoreGraphics
import Foundation
import ImageIO
import PalProtocol
import PalSettings
import PalTransport
import Synchronization
import Testing

private func bitmap(width: Int, height: Int, alpha: Bool = false, noise: Bool = false, paint: (CGContext) -> Void = { _ in }) throws -> CGImage {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
    ))
    if noise, let data = context.data {
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var state: UInt64 = 0x9E3779B97F4A7C15
        for index in 0..<(context.bytesPerRow * height) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
    } else if !alpha {
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    paint(context)
    return try #require(context.makeImage())
}

private func encoded(_ image: CGImage, type: String, orientation: Int? = nil, quality: Double? = nil) throws -> Data {
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
    var properties: [CFString: Any] = [:]
    if let orientation { properties[kCGImagePropertyOrientation] = orientation }
    if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

private struct RGB8 {
    let r: Int
    let g: Int
    let b: Int
}

private func pixel(_ image: CGImage, x: Int, y: Int) throws -> RGB8 {
    var buffer = [UInt8](repeating: 0, count: 4)
    let context = try #require(CGContext(
        data: &buffer, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return RGB8(r: Int(buffer[0]), g: Int(buffer[1]), b: Int(buffer[2]))
}

private func decodedJPEG(_ data: Data) throws -> (image: CGImage, type: String) {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return (try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)), CGImageSourceGetType(source) as String? ?? "")
}

@Suite("Owner photo crop geometry")
struct PhotoCropTests {
    private let square = CGSize(width: 1000, height: 1000)
    private let wide = CGSize(width: 2000, height: 1000)
    private let tall = CGSize(width: 1000, height: 3000)

    @Test func fillsTheCircleWithTheShortSideAtDefaultZoom() {
        #expect(PhotoCrop().sourceRect(in: square) == CGRect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(PhotoCrop().sourceRect(in: wide) == CGRect(x: 500, y: 0, width: 1000, height: 1000))
        #expect(PhotoCrop().sourceRect(in: tall) == CGRect(x: 0, y: 1000, width: 1000, height: 1000))
    }

    @Test func zoomShrinksTheSourceSquareAroundTheCenter() {
        let crop = PhotoCrop().zoomed(to: 2, in: square)
        #expect(crop.sourceRect(in: square) == CGRect(x: 250, y: 250, width: 500, height: 500))
    }

    @Test func zoomIsClampedToTheSupportedRange() {
        #expect(PhotoCrop().zoomed(to: 0.2, in: square).zoom == 1)
        #expect(PhotoCrop().zoomed(to: 99, in: square).zoom == PhotoCrop.zoomRange.upperBound)
        #expect(PhotoCrop().zoomed(to: .nan, in: square).zoom.isFinite)
    }

    @Test func draggingTheImageRightMovesTheSourceWindowLeft() {
        let crop = PhotoCrop().zoomed(to: 2, in: square)
        let moved = crop.moved(byPoints: CGSize(width: 50, height: -25), circle: 200, in: square)
        let rect = moved.sourceRect(in: square)
        #expect(rect.width == 500)
        #expect(abs(rect.minX - 125) < 0.001)
        #expect(abs(rect.minY - 312.5) < 0.001)
    }

    @Test func draggingNeverExposesEmptySpace() {
        let crop = PhotoCrop().zoomed(to: 2, in: square)
        let far = crop.moved(byPoints: CGSize(width: 100_000, height: -100_000), circle: 200, in: square)
        let rect = far.sourceRect(in: square)
        #expect(rect.minX == 0)
        #expect(rect.maxY == 1000)
        let other = crop.moved(byPoints: CGSize(width: -100_000, height: 100_000), circle: 200, in: square)
        #expect(other.sourceRect(in: square).maxX == 1000)
        #expect(other.sourceRect(in: square).minY == 0)
    }

    @Test func zoomingOutAfterADragKeepsTheWindowInsideTheImage() {
        let zoomed = PhotoCrop().zoomed(to: 4, in: square).moved(byPoints: CGSize(width: -100_000, height: 0), circle: 200, in: square)
        let out = zoomed.zoomed(to: 1, in: square)
        #expect(out.sourceRect(in: square) == CGRect(x: 0, y: 0, width: 1000, height: 1000))
    }

    @Test func aWideImagePansAlongItsLongSideOnly() {
        let moved = PhotoCrop().moved(byPoints: CGSize(width: -100_000, height: 100_000), circle: 200, in: wide)
        #expect(moved.sourceRect(in: wide) == CGRect(x: 1000, y: 0, width: 1000, height: 1000))
    }

    @Test func degenerateInputLeavesTheCropUnchanged() {
        let crop = PhotoCrop()
        #expect(crop.moved(byPoints: CGSize(width: 10, height: 10), circle: 0, in: square) == crop)
        #expect(crop.moved(byPoints: CGSize(width: 10, height: 10), circle: 200, in: .zero) == crop)
    }
}

@Suite("Owner photo image processing")
struct OwnerPhotoImageTests {
    @Test(arguments: ["public.png", "public.jpeg", "public.heic"])
    func acceptedFormatsBecomeA512SquareJPEGUnderTheServerCap(type: String) throws {
        let source = try encoded(try bitmap(width: 1600, height: 1000, noise: true), type: type)
        let image = try OwnerPhotoImage.decode(source)
        let upload = try OwnerPhotoImage.jpeg(cropping: image, to: PhotoCrop())
        let (result, resultType) = try decodedJPEG(upload)
        #expect(resultType == "public.jpeg")
        #expect(result.width == OwnerPhotoImage.edge)
        #expect(result.height == OwnerPhotoImage.edge)
        #expect(upload.count < OwnerPhotoImage.maximumUploadBytes)
        #expect(OwnerPhotoImage.maximumUploadBytes <= 2_000_000)
    }

    @Test func aHugeNoisyPhotoStillEncodesUnderTheCap() throws {
        let source = try encoded(try bitmap(width: 4000, height: 3000, noise: true), type: "public.jpeg", quality: 0.2)
        #expect(source.count < OwnerPhotoImage.maximumSourceBytes)
        let image = try OwnerPhotoImage.decode(source)
        #expect(max(image.width, image.height) <= OwnerPhotoImage.workingPixels)
        let upload = try OwnerPhotoImage.jpeg(cropping: image, to: PhotoCrop().zoomed(to: 3, in: CGSize(width: image.width, height: image.height)))
        #expect(upload.count < OwnerPhotoImage.maximumUploadBytes)
    }

    @Test func aSmallPhotoIsNotUpscaledWhenDecoded() throws {
        let image = try OwnerPhotoImage.decode(try encoded(try bitmap(width: 300, height: 200), type: "public.png"))
        #expect(image.width == 300)
        #expect(image.height == 200)
    }

    @Test func exifOrientationIsAppliedBeforeCropping() throws {
        let landscape = try bitmap(width: 400, height: 200)
        let image = try OwnerPhotoImage.decode(try encoded(landscape, type: "public.jpeg", orientation: 6))
        #expect(image.width == 200)
        #expect(image.height == 400)
    }

    @Test func theCropWindowDecidesWhichPixelsAreSaved() throws {
        let split = try bitmap(width: 800, height: 400) { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 400, y: 0, width: 400, height: 400))
        }
        let size = CGSize(width: 800, height: 400)
        let left = PhotoCrop().moved(byPoints: CGSize(width: 100_000, height: 0), circle: 200, in: size)
        let right = PhotoCrop().moved(byPoints: CGSize(width: -100_000, height: 0), circle: 200, in: size)
        let leftPixel = try pixel(try decodedJPEG(try OwnerPhotoImage.jpeg(cropping: split, to: left)).image, x: 256, y: 256)
        let rightPixel = try pixel(try decodedJPEG(try OwnerPhotoImage.jpeg(cropping: split, to: right)).image, x: 256, y: 256)
        #expect(leftPixel.r > 200 && leftPixel.b < 60)
        #expect(rightPixel.b > 200 && rightPixel.r < 60)
    }

    @Test func aTransparentPngIsFlattenedOnWhiteNotBlack() throws {
        let clear = try bitmap(width: 300, height: 300, alpha: true)
        let image = try OwnerPhotoImage.decode(try encoded(clear, type: "public.png"))
        let upload = try OwnerPhotoImage.jpeg(cropping: image, to: PhotoCrop())
        let center = try pixel(try decodedJPEG(upload).image, x: 256, y: 256)
        #expect(center.r > 240 && center.g > 240 && center.b > 240)
    }

    @Test func aSourceOverTenMegabytesIsRefusedBeforeDecoding() {
        #expect(throws: OwnerPhotoImage.Failure.tooLarge) {
            try OwnerPhotoImage.decode(Data(count: OwnerPhotoImage.maximumSourceBytes + 1))
        }
    }

    @Test func aFileOverTenMegabytesIsRefusedFromItsSizeAlone() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "owner-photo-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: OwnerPhotoImage.maximumSourceBytes + 1).write(to: url)
        #expect(throws: OwnerPhotoImage.Failure.tooLarge) { try OwnerPhotoImage.decode(contentsOf: url) }
    }

    @Test func aMissingFileIsUnreadableAndARealFileDecodes() throws {
        let directory = FileManager.default.temporaryDirectory
        let missing = directory.appending(path: "owner-photo-\(UUID().uuidString).png")
        #expect(throws: OwnerPhotoImage.Failure.unreadable) { try OwnerPhotoImage.decode(contentsOf: missing) }
        let url = directory.appending(path: "owner-photo-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: url) }
        try encoded(try bitmap(width: 320, height: 240), type: "public.heic").write(to: url)
        let image = try OwnerPhotoImage.decode(contentsOf: url)
        #expect(image.width == 320 && image.height == 240)
    }

    @Test func nonImagesAndOtherFormatsAreUnsupported() throws {
        #expect(throws: OwnerPhotoImage.Failure.unsupported) { try OwnerPhotoImage.decode(Data("not an image".utf8)) }
        #expect(throws: OwnerPhotoImage.Failure.unsupported) { try OwnerPhotoImage.decode(Data()) }
        let gif = try encoded(try bitmap(width: 40, height: 40), type: "com.compuserve.gif")
        #expect(throws: OwnerPhotoImage.Failure.unsupported) { try OwnerPhotoImage.decode(gif) }
    }

    @Test func aTruncatedJpegIsUnreadableNotACrash() throws {
        let whole = try encoded(try bitmap(width: 600, height: 600, noise: true), type: "public.jpeg")
        let header = whole.prefix(64)
        #expect(throws: OwnerPhotoImage.Failure.self) { try OwnerPhotoImage.decode(Data(header)) }
    }
}

@Suite("Owner profile wire")
struct OwnerProfileWireTests {
    private final class Recorder: Sendable {
        private let storage = Mutex<[(String, JSONValue?)]>([])
        var calls: [(String, JSONValue?)] { storage.withLock { $0 } }
        func record(_ method: String, _ params: JSONValue?) { storage.withLock { $0.append((method, params)) } }
    }

    private static func api(reply: JSONValue = .object([:]), error: (any Error)? = nil, recorder: Recorder) -> SettingsAPI {
        SettingsAPI(profile: "default") { method, params in
            recorder.record(method, params)
            if let error { throw error }
            return reply
        }
    }

    @Test func aboutYouDecodesThePhotoVersionAndToleratesEnginesWithoutIt() throws {
        let json = #"{"name":"Anh","timezone":"UTC","timezone_auto":true,"photo_version":"abc123"}"#
        let with = try SettingsWire.decoder.decode(SettingsWire.AboutYou.self, from: Data(json.utf8))
        #expect(with == SettingsWire.AboutYou(name: "Anh", timezone: "UTC", timezoneAuto: true, photoVersion: "abc123"))
        let without = try SettingsWire.decoder.decode(SettingsWire.AboutYou.self, from: Data(#"{"name":"Anh","timezone":"","timezone_auto":false}"#.utf8))
        #expect(without.photoVersion == "")
    }

    @Test func settingTheNameSendsOnlyTheNameAndTheProfile() async throws {
        let recorder = Recorder()
        let api = Self.api(reply: ["name": "Anh", "timezone": "", "timezone_auto": false, "photo_version": ""], recorder: recorder)
        let facts = try await api.setOwnerName("Anh")
        #expect(facts.name == "Anh")
        let call = try #require(recorder.calls.first)
        #expect(call.0 == "bot_mode.about_you.set")
        #expect(call.1 == ["name": "Anh", "profile": "default"])
    }

    @Test func uploadingSendsPlainBase64AndRemovingSendsNull() async throws {
        let recorder = Recorder()
        let api = Self.api(reply: ["name": "", "timezone": "", "timezone_auto": false, "photo_version": "v1"], recorder: recorder)
        let facts = try await api.setOwnerPhoto(Data([1, 2, 3]))
        _ = try await api.setOwnerPhoto(nil)
        #expect(facts.photoVersion == "v1")
        #expect(recorder.calls[0].0 == "bot_mode.about_you.set_photo")
        #expect(recorder.calls[0].1?["data"] == "AQID")
        #expect(recorder.calls[1].1?["data"] == .null)
    }

    @Test func anOversizedUploadIsRefusedWithoutACall() async {
        let recorder = Recorder()
        let api = Self.api(recorder: recorder)
        await #expect(throws: SettingsFailure.rejected(code: "photo_too_large")) {
            try await api.setOwnerPhoto(Data(count: OwnerPhotoImage.maximumUploadBytes + 1))
        }
        #expect(recorder.calls.isEmpty)
    }

    @Test func downloadDecodesTheImageAndAnEmptyVersionMeansNoPhoto() async throws {
        let recorder = Recorder()
        let some = Self.api(reply: ["data": "AQID", "mime": "image/jpeg", "photo_version": "v1"], recorder: recorder)
        #expect(try await some.ownerPhoto() == OwnerPhotoDownload(version: "v1", data: Data([1, 2, 3])))
        let none = Self.api(reply: ["data": "", "mime": "", "photo_version": ""], recorder: recorder)
        #expect(try await none.ownerPhoto() == nil)
        let garbled = Self.api(reply: ["data": "***", "mime": "image/jpeg", "photo_version": "v2"], recorder: recorder)
        await #expect(throws: SettingsFailure.unexpected) { try await garbled.ownerPhoto() }
    }

    @Test(arguments: [4068, 4069, 4070])
    func photoRejectionsReadAsProductLanguage(code: Int) async {
        let recorder = Recorder()
        let api = Self.api(error: GatewayTransportError.rpc(RPCError(code: code, message: "raw server text")), recorder: recorder)
        do {
            _ = try await api.setOwnerPhoto(Data([1]))
            Issue.record("expected a failure")
        } catch let failure as SettingsFailure {
            #expect(failure.message == "That picture couldn't be used. Try a JPEG or PNG under 10 MB.")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test(arguments: [4068, 4069, 4070])
    func theEnginesOwnErrorShapeStillReadsAsProductLanguage(code: Int) async {
        let recorder = Recorder()
        let data: JSONValue = ["reason": "internal", "trace": "abc", "gateway_version": "00040766"]
        let api = Self.api(error: GatewayTransportError.rpc(RPCError(code: code, message: "asset too large (max 2MB)", data: data)), recorder: recorder)
        await #expect(throws: SettingsFailure.rejected(code: code == 4068 ? "photo_unreadable" : code == 4069 ? "photo_too_large" : "photo_format")) {
            _ = try await api.setOwnerPhoto(Data([1]))
        }
    }

    @Test func aStorageFailureIsUnavailableNotARawServerMessage() async {
        let recorder = Recorder()
        let api = Self.api(error: GatewayTransportError.rpc(RPCError(code: 5067, message: "disk full at /x")), recorder: recorder)
        await #expect(throws: SettingsFailure.unavailable) { _ = try await api.setOwnerName("A") }
    }
}

@Suite("Owner intro dismissal")
struct OwnerIntroStoreTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "owner-intro-\(UUID().uuidString)")!
    }

    @Test func startsUndismissedAndKeepsADismissalAcrossStoreInstances() {
        let defaults = defaults()
        #expect(!OwnerIntroStore(defaults: defaults, account: "https://pi|anh").isDismissed)
        OwnerIntroStore(defaults: defaults, account: "https://pi|anh").dismiss()
        #expect(OwnerIntroStore(defaults: defaults, account: "https://pi|anh").isDismissed)
    }

    @Test func aDismissalBelongsToOneAccountOnly() {
        let defaults = defaults()
        OwnerIntroStore(defaults: defaults, account: "https://pi|anh").dismiss()
        #expect(!OwnerIntroStore(defaults: defaults, account: "https://pi|other").isDismissed)
        #expect(!OwnerIntroStore(defaults: defaults, account: "https://elsewhere|anh").isDismissed)
    }
}
