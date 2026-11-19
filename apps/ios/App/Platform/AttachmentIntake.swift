import Observation
import PalChat
import PalDesign
import PalDiagnostics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

typealias IntakeHandler = @MainActor @Sendable (DropBatch) -> Void

extension View {
    func attachmentIntake(intake: @escaping IntakeHandler, targeting: DropTargeting? = nil) -> some View {
        modifier(AttachmentIntakeModifier(intake: intake, injected: targeting))
    }

    func attachmentPaste(intake: @escaping IntakeHandler) -> some View {
        modifier(AttachmentPasteModifier(intake: intake))
    }
}

@MainActor @Observable
final class DropTargeting {
    var isTargeted = false
}

private struct AttachmentIntakeModifier: ViewModifier {
    let intake: IntakeHandler
    let injected: DropTargeting?

    @State private var owned = DropTargeting()

    private var targeting: DropTargeting { injected ?? owned }

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onDrop(of: [.item], delegate: AttachmentDropDelegate(targeting: targeting, intake: intake))
            .overlay { DropOverlay(targeting: targeting) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                targeting.isTargeted = false
            }
            .onDisappear { targeting.isTargeted = false }
        #else
        content
        #endif
    }
}

private struct AttachmentPasteModifier: ViewModifier {
    let intake: IntakeHandler

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onPasteCommand(of: [.fileURL, .image]) { providers in
                _ = AttachmentIntake.receive(providers, intake: intake)
            }
        #else
        if #available(iOS 27.0, *) {
            content
                .pasteDestination(for: Data.self) { datas in
                    intake(DropBatch(images: datas))
                } validator: { datas in
                    datas.filter(AttachmentIntake.isImage)
                }
        } else {
            content
        }
        #endif
    }
}

#if os(macOS)
private struct DropOverlay: View {
    let targeting: DropTargeting

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        if targeting.isTargeted {
            RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color(theme.palette.primaryBadge), lineWidth: 2)
                .padding(2)
                .allowsHitTesting(false)
                .accessibilityIdentifier("composerDropTarget")
        }
    }
}

@MainActor
private struct AttachmentDropDelegate: DropDelegate {
    let targeting: DropTargeting
    let intake: IntakeHandler

    func validateDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.item])
        return providers.isEmpty || providers.contains { DropSource.classify(typeIdentifiers: $0.registeredTypeIdentifiers) != .text }
    }

    func dropEntered(info: DropInfo) {
        targeting.isTargeted = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        targeting.isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        targeting.isTargeted = false
        return AttachmentIntake.receive(info.itemProviders(for: [.item]), intake: intake)
    }
}
#endif

enum AttachmentIntake {
    nonisolated static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return false }
        return true
    }

    #if os(macOS)
    private static let diagnostics = Diagnostics.osLog()

    @MainActor static func receive(_ providers: [NSItemProvider], intake: @escaping IntakeHandler) -> Bool {
        let candidates = providers
            .map { ($0, DropSource.classify(typeIdentifiers: $0.registeredTypeIdentifiers)) }
            .filter { $0.1 != .text }
        guard !candidates.isEmpty else { return false }
        Task {
            var batch = DropBatch()
            for (provider, source) in candidates { await collect(provider, as: source, into: &batch) }
            batch.failures.forEach { diagnostics.info("attachments", "drop not attached: \($0)") }
            intake(batch)
        }
        return true
    }

    @MainActor private static func collect(_ provider: NSItemProvider, as source: DropSource, into batch: inout DropBatch) async {
        switch source {
        case .fileURL:
            if let url = await fileURL(from: provider) { batch.files.append(url) } else { batch.failures.append(.unreadable) }
        case .image(let identifier):
            if let data = await data(from: provider, identifier: identifier) {
                batch.images.append(data)
            } else if let copy = await copiedFile(from: provider, identifier: identifier) {
                batch.files.append(copy.file)
                batch.temporaryDirectories.append(copy.directory)
            } else {
                batch.failures.append(.unreadable)
            }
        case .content(let identifier):
            if let copy = await copiedFile(from: provider, identifier: identifier) {
                batch.files.append(copy.file)
                batch.temporaryDirectories.append(copy.directory)
            } else {
                batch.failures.append(.unreadable)
            }
        case .webLink:
            if let url = await fileURL(from: provider) { batch.files.append(url) } else { batch.failures.append(.webLinkOnly) }
        case .text:
            break
        case .unsupported:
            batch.failures.append(.unsupported)
        }
    }

    @MainActor private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    @MainActor private static func data(from provider: NSItemProvider, identifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data?.isEmpty == false ? data : nil)
            }
        }
    }

    @MainActor private static func copiedFile(from provider: NSItemProvider, identifier: String) async -> (file: URL, directory: URL)? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let directory = FileManager.default.temporaryDirectory.appending(path: "pal-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
                let destination = directory.appending(path: url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: (destination, directory))
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    #endif
}
