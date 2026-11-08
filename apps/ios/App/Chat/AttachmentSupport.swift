import ImageIO
import SwiftUI
import UIKit
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
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85)
        else { throw AttachmentError.unreadable }
        let preview = thumbnail(of: source, maxPixels: thumbnailDimension).flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.7) }
        return PreparedUpload(data: jpeg, filename: jpegName(name), thumbnail: preview)
    }

    nonisolated static func prepareImage(from image: UIImage) throws -> PreparedUpload {
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

struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
