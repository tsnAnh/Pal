import CoreGraphics
import Foundation
import PDFKit
import QuickLookThumbnailing

public struct SystemDocumentThumbnailGenerator: DocumentThumbnailGenerating {
    public init() {}

    public func thumbnail(forFileAt url: URL, kind: ChatDocumentKind?, maxPixel: Int) async throws -> GeneratedThumbnail? {
        let pages = kind == .pdf ? PDFDocument(url: url)?.pageCount : nil
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: maxPixel, height: maxPixel * 3 / 2), scale: 1, representationTypes: .thumbnail
        )
        try Task.checkCancellation()
        let image: CGImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.cgImage)
            }
        }
        try Task.checkCancellation()
        guard let image, let jpeg = AVMediaPosterGenerator.encode(image) else { return nil }
        return GeneratedThumbnail(jpeg: jpeg, pageCount: pages, width: image.width, height: image.height)
    }
}
