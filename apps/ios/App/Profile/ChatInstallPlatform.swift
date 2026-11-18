import PalDesign
import SwiftUI
#if os(macOS)
import AppKit
#else
import Photos
#endif

enum ChatAvatarExport {
    static let pixels: CGFloat = 1024

    @MainActor
    static func render(spec: BotAvatarSpec, background: Color) -> CGImage? {
        let content = BotAvatarView(spec: spec, size: pixels * 0.8, animated: false)
            .frame(width: pixels, height: pixels)
            .background(background)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.cgImage
    }

    #if os(macOS)
    static let actionTitle = String(localized: "Show picture in Finder")
    static let explanation = String(localized: "Pal saved the picture as a file. Drag it onto the App icon box on the Slack page.")

    @MainActor
    static func deliver(_ image: CGImage, name: String) async -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name) for Slack.png")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return false
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }
    #else
    static let actionTitle = String(localized: "Save picture to Photos")
    static let explanation = String(
        localized: "Pal adds the picture to your Photos. It only asks to add, never to see your photos. Then upload it on the Slack page."
    )

    @MainActor
    static func deliver(_ image: CGImage, name: String) async -> Bool {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized,
              let data = UIImage(cgImage: image).pngData() else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return true
        } catch {
            return false
        }
    }
    #endif
}
