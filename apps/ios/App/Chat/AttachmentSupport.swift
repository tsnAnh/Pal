import ImageIO
import PalChat
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum AttachmentError: Error {
    case unreadable
    case tooLarge
}

enum AttachmentPreparer {
    static let maximumBytes = 24 * 1024 * 1024
    private static let maximumImageDimension = 2048
    private static let thumbnailDimension = 160

    nonisolated static func prepareImage(from data: Data, name: String? = nil) throws -> PreparedUpload {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = thumbnail(of: source, maxPixels: maximumImageDimension),
              let jpeg = PlatformImage(cgImage: image).jpegData(compressionQuality: 0.85)
        else { throw AttachmentError.unreadable }
        let preview = thumbnail(of: source, maxPixels: thumbnailDimension).flatMap { PlatformImage(cgImage: $0).jpegData(compressionQuality: 0.7) }
        return PreparedUpload(data: jpeg, filename: jpegName(name), thumbnail: preview)
    }

    nonisolated static func prepareImage(from image: PlatformImage) throws -> PreparedUpload {
        guard let data = image.jpegData(compressionQuality: 0.95) else { throw AttachmentError.unreadable }
        return try prepareImage(from: data)
    }

    nonisolated static func prepareFile(at url: URL) throws -> (upload: PreparedUpload, mime: String, isImage: Bool) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        if let size = values?.fileSize, size > maximumBytes { throw AttachmentError.tooLarge }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw AttachmentError.unreadable }
        guard data.count <= maximumBytes else { throw AttachmentError.tooLarge }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .image) {
            return (try prepareImage(from: data, name: url.deletingPathExtension().lastPathComponent), "image/jpeg", true)
        }
        let name = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        return (PreparedUpload(data: data, filename: name, thumbnail: nil), mime, false)
    }

    private nonisolated static func thumbnail(of source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func jpegName(_ name: String?) -> String {
        let stem = (name?.isEmpty == false ? name! : "photo-\(Int(Date().timeIntervalSince1970))")
        let cleaned = stem.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "-" }
        return String(cleaned) + ".jpg"
    }
}

struct AttachmentSink {
    let photo: @MainActor (PreparedUpload) -> Void
    let file: @MainActor (PreparedUpload, String) -> Void
    let fail: @MainActor (String) -> Void
}

@MainActor
enum AttachmentStager {
    static func stage(_ batch: DropBatch, into sink: AttachmentSink) async {
        defer { batch.temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) } }
        if let summary = DropFailure.summary(of: batch.failures) { sink.fail(summary) }
        await stage(files: batch.files, into: sink)
        for data in batch.images { await stage(imageData: data, into: sink) }
    }

    static func stage(photos items: [PhotosPickerItem], into sink: AttachmentSink) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                sink.fail(String(localized: "That photo couldn't be loaded."))
                continue
            }
            await stage(imageData: data, into: sink)
        }
    }

    static func stage(imageData data: Data, into sink: AttachmentSink) async {
        do {
            sink.photo(try await Task.detached { try AttachmentPreparer.prepareImage(from: data) }.value)
        } catch {
            sink.fail(String(localized: "That photo couldn't be prepared."))
        }
    }

    static func stage(image: PlatformImage, into sink: AttachmentSink) async {
        do {
            sink.photo(try await Task.detached { try AttachmentPreparer.prepareImage(from: image) }.value)
        } catch {
            sink.fail(String(localized: "That photo couldn't be prepared."))
        }
    }

    static func stage(files urls: [URL], into sink: AttachmentSink) async {
        let items = DropIntake.classify(urls)
        if let message = DropIntake.rejectionMessage(for: items) { sink.fail(message) }
        for item in items {
            let url: URL
            switch item {
            case .image(let accepted), .document(let accepted): url = accepted
            case .rejected: continue
            }
            do {
                let prepared = try await Task.detached { try AttachmentPreparer.prepareFile(at: url) }.value
                if prepared.isImage { sink.photo(prepared.upload) } else { sink.file(prepared.upload, prepared.mime) }
            } catch AttachmentError.tooLarge {
                sink.fail(DropFailure.tooLarge(limitMegabytes: AttachmentPreparer.maximumBytes / (1024 * 1024)).message)
            } catch {
                sink.fail(DropFailure.unreadable.message)
            }
        }
    }
}
