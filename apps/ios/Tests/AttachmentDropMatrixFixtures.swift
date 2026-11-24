#if os(macOS)
import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

final class MatrixPromiseDelegate: NSObject, @preconcurrency NSFilePromiseProviderDelegate, @unchecked Sendable {
    let data: Data
    let name: String

    init(data: Data, name: String) {
        self.data = data
        self.name = name
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try data.write(to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

struct MatrixSource {
    let name: String
    let attaches: Bool
    let write: @MainActor (NSPasteboard) -> Void
}

@MainActor
final class MatrixFixtures {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.tsnanh.pal.drop-matrix"))
    let directory = FileManager.default.temporaryDirectory.appending(path: "drop-matrix-\(UUID().uuidString)", directoryHint: .isDirectory)
    var delegates: [MatrixPromiseDelegate] = []
    let image: NSImage
    let bitmap: NSBitmapImageRep
    let png: Data

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let drawn = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(drawn.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let encodedPNG = try #require(rep.representation(using: .png, properties: [:]))
        image = drawn
        bitmap = rep
        png = encodedPNG
    }

    func encoded(_ type: UTType) -> Data {
        guard let cgImage = bitmap.cgImage else { return png }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else { return png }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : png
    }

    func file(_ name: String, _ contents: Data) -> URL {
        let url = directory.appending(path: name)
        try? contents.write(to: url)
        return url
    }

    func single(_ pasteboard: NSPasteboard, _ build: (NSPasteboardItem) -> Void) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        build(item)
        pasteboard.writeObjects([item])
    }

    func promise(_ pasteboard: NSPasteboard, type: UTType, name: String, data: Data) {
        let delegate = MatrixPromiseDelegate(data: data, name: name)
        delegates.append(delegate)
        pasteboard.clearContents()
        pasteboard.writeObjects([NSFilePromiseProvider(fileType: type.identifier, delegate: delegate)])
    }

    var sources: [MatrixSource] {
        let pdf = Data("%PDF-1.1\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF".utf8)
        return [
            MatrixSource(name: "Finder file URL", attaches: true) { pasteboard in
                let url = self.file("note.png", self.png)
                self.single(pasteboard) {
                    $0.setString(url.absoluteString, forType: .fileURL)
                    $0.setString(url.lastPathComponent, forType: .string)
                }
            },
            MatrixSource(name: "PNG data", attaches: true) { pasteboard in self.single(pasteboard) { $0.setData(self.png, forType: .png) } },
            MatrixSource(name: "JPEG data", attaches: true) { pasteboard in
                self.single(pasteboard) { $0.setData(self.encoded(.jpeg), forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) }
            },
            MatrixSource(name: "HEIC data", attaches: true) { pasteboard in
                self.single(pasteboard) { $0.setData(self.encoded(.heic), forType: NSPasteboard.PasteboardType(UTType.heic.identifier)) }
            },
            MatrixSource(name: "TIFF data", attaches: true) { pasteboard in
                self.single(pasteboard) { $0.setData(self.bitmap.tiffRepresentation ?? self.png, forType: .tiff) }
            },
            MatrixSource(name: "screenshot thumbnail (promise)", attaches: true) { pasteboard in
                self.promise(pasteboard, type: .png, name: "Screenshot.png", data: self.png)
            },
            MatrixSource(name: "Safari/Chrome image (url+html+image)", attaches: true) { pasteboard in
                self.single(pasteboard) {
                    $0.setString("https://example.com/photo.png", forType: .URL)
                    $0.setString("https://example.com/photo.png", forType: .string)
                    $0.setString("<img src=\"https://example.com/photo.png\">", forType: .html)
                    $0.setData(self.png, forType: .png)
                }
            },
            MatrixSource(name: "Photos (promise)", attaches: true) { pasteboard in
                self.promise(pasteboard, type: .jpeg, name: "IMG_0001.jpeg", data: self.encoded(.jpeg))
            },
            MatrixSource(name: "PDF Finder file", attaches: true) { pasteboard in
                let url = self.file("report.pdf", pdf)
                self.single(pasteboard) {
                    $0.setString(url.absoluteString, forType: .fileURL)
                    $0.setString(url.lastPathComponent, forType: .string)
                }
            },
            MatrixSource(name: "PDF data only", attaches: true) { pasteboard in self.single(pasteboard) { $0.setData(pdf, forType: .pdf) } },
            MatrixSource(name: "plain text", attaches: false) { pasteboard in self.single(pasteboard) { $0.setString("hello", forType: .string) } },
        ]
    }
}
#endif
