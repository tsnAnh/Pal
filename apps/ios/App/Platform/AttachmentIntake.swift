import Observation
import PalChat
import PalDesign
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

typealias IntakeHandler = @MainActor @Sendable (DropBatch) -> Void

extension View {
    func attachmentIntake(
        botName: String,
        accent: BotAccent?,
        intake: @escaping IntakeHandler,
        targeting: DropTargeting? = nil
    ) -> some View {
        modifier(AttachmentIntakeModifier(botName: botName, accent: accent, intake: intake, injected: targeting))
    }

    func attachmentPaste(intake: @escaping IntakeHandler) -> some View {
        modifier(AttachmentPasteModifier(intake: intake))
    }
}

@MainActor @Observable
final class DropTargeting {
    var isTargeted = false
    var itemCount = 1
}

private struct AttachmentIntakeModifier: ViewModifier {
    let botName: String
    let accent: BotAccent?
    let intake: IntakeHandler
    let injected: DropTargeting?

    @State private var owned = DropTargeting()

    private var targeting: DropTargeting { injected ?? owned }

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .overlay { AttachmentDropAnchor(targeting: targeting, intake: intake).allowsHitTesting(false) }
            .overlay { DropOverlay(targeting: targeting, botName: botName, accent: accent) }
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

enum AttachmentIntake {
    nonisolated static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return false }
        return true
    }

    #if os(macOS)
    @MainActor static func receive(_ providers: [NSItemProvider], intake: @escaping IntakeHandler) -> Bool {
        receive(payloads: providers.map { ProviderPayload(provider: $0) as any DropPayload }, intake: intake)
    }

    @MainActor static func receive(payloads: [any DropPayload], intake: @escaping IntakeHandler) -> Bool {
        let items = payloads.map { $0.typeIdentifiers }
        let candidates = payloads
            .map { ($0, DropSource.classify(typeIdentifiers: $0.typeIdentifiers)) }
            .filter { $0.1 != .text }
        guard !candidates.isEmpty else {
            DropTrace.note("receive", items: items, destination: "intake", verdict: "refuse", refusal: "no-candidates")
            return false
        }
        DropTrace.note("receive", items: items, destination: "intake", verdict: "accept")
        Task {
            var batch = DropBatch()
            for (payload, source) in candidates { await collect(payload, as: source, into: &batch) }
            let failures = batch.failures.map(\.label)
            DropTrace.diagnostics.notice(
                "attachments", "drop loaded files=\(batch.files.count) images=\(batch.images.count) failures=\(failures)"
            )
            intake(batch)
        }
        return true
    }

    @MainActor private static func collect(_ payload: any DropPayload, as source: DropSource, into batch: inout DropBatch) async {
        switch source {
        case .fileURL:
            if let url = await payload.fileURL() { batch.files.append(url) } else { batch.failures.append(.unreadable) }
        case .image(let identifier):
            if let data = await payload.data(identifier: identifier) {
                batch.images.append(data)
            } else {
                await collectContent(payload, identifier: identifier, into: &batch)
            }
        case .content(let identifier):
            await collectContent(payload, identifier: identifier, into: &batch)
        case .webLink:
            if let url = await payload.fileURL() { batch.files.append(url) } else { batch.failures.append(.webLinkOnly) }
        case .text:
            break
        case .unsupported:
            batch.failures.append(.unsupported)
        }
    }

    @MainActor private static func collectContent(_ payload: any DropPayload, identifier: String, into batch: inout DropBatch) async {
        guard let copy = await payload.copiedFile(identifier: identifier) else {
            batch.failures.append(.unreadable)
            return
        }
        batch.files.append(copy.file)
        batch.temporaryDirectories.append(copy.directory)
    }
    #endif
}
