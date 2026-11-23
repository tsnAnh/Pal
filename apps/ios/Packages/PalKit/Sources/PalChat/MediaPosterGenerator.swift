import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct GeneratedPoster: Sendable, Equatable {
    public let jpeg: Data
    public let duration: TimeInterval?
    public let width: Int
    public let height: Int
}

public protocol MediaPosterGenerator: Sendable {
    func poster(forFileAt url: URL, maxPixel: Int) async throws -> GeneratedPoster?
}

public struct AVMediaPosterGenerator: MediaPosterGenerator {
    public init() {}

    public func poster(forFileAt url: URL, maxPixel: Int) async throws -> GeneratedPoster? {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let moment = CMTime(seconds: min(1, (seconds ?? 2) / 2), preferredTimescale: 600)
        let frame: CGImage
        do {
            frame = try await generator.image(at: moment).image
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        guard let jpeg = Self.encode(frame) else { return nil }
        return GeneratedPoster(jpeg: jpeg, duration: seconds, width: frame.width, height: frame.height)
    }

    static func encode(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
