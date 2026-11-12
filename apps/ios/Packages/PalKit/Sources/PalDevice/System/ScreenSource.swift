#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
@preconcurrency import Vision

public struct SystemScreenSource: ScreenSource {
    private static let recognitionLongEdge = 4096

    public init() {}

    public func frame(display: Int, longEdge: Int, maximumBytes: Int) async throws -> ScreenFrame {
        let image = try await Self.image(display: display, longEdge: longEdge)
        guard let jpeg = Self.encode(image, maximumBytes: maximumBytes) else {
            throw DeviceProviderError.failed("The screenshot is too large to send.")
        }
        return ScreenFrame(jpeg: jpeg, width: image.width, height: image.height)
    }

    public func text(display: Int) async throws -> String {
        let image = try await Self.image(display: display, longEdge: Self.recognitionLongEdge)
        return try await Task.detached(priority: .userInitiated) { try Self.recognize(image) }.value
    }

    private static func image(display number: Int, longEdge: Int) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw DeviceProviderError.permissionDenied }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) } catch {
            throw DeviceProviderError.failed("The list of displays could not be read.")
        }
        let main = CGMainDisplayID()
        let displays = content.displays.sorted { left, right in
            if (left.displayID == main) != (right.displayID == main) { return left.displayID == main }
            return left.displayID < right.displayID
        }
        guard number >= 1, number <= displays.count else {
            throw DeviceProviderError.invalidArgs("There is no display \(number). This Mac has \(displays.count).")
        }
        let display = displays[number - 1]
        let size = scaled(width: display.width, height: display.height, longEdge: longEdge)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = true
        let filter = SCContentFilter(display: display, excludingWindows: [])
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw DeviceProviderError.failed("The screen could not be captured.")
        }
    }

    static func scaled(width: Int, height: Int, longEdge: Int) -> (width: Int, height: Int) {
        let longest = max(width, height, 1)
        guard longest > longEdge else { return (max(width, 1), max(height, 1)) }
        let factor = Double(longEdge) / Double(longest)
        return (max(Int((Double(width) * factor).rounded()), 1), max(Int((Double(height) * factor).rounded()), 1))
    }

    private static func encode(_ image: CGImage, maximumBytes: Int) -> Data? {
        for quality in [0.7, 0.55, 0.4, 0.25] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if data.length <= maximumBytes { return data as Data }
        }
        return nil
    }

    private static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch {
            throw DeviceProviderError.failed("The text on the screen could not be read.")
        }
        let observations: [VNRecognizedTextObservation] = request.results ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
#endif
