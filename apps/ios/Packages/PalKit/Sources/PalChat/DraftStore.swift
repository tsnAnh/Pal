import Foundation
import PalDiagnostics
import Synchronization

public enum DraftError: Error, Sendable, Equatable {
    case tooLarge
    case tooMany
}

public final class DraftStore: Sendable {
    public static let maximumAttachments = 10
    public static let maximumAttachmentBytes = 25 * 1024 * 1024

    private struct State {
        var drafts: [String: ComposerDraft] = [:]
        var pending: Set<String> = []
        var timer: Task<Void, Never>?
        var writeCount = 0
    }

    private let directory: URL
    private let debounce: Duration
    private let diagnostics: Diagnostics
    private let state = Mutex(State())

    public init(directory: URL, debounce: Duration = .milliseconds(400), diagnostics: Diagnostics = .silent) {
        self.directory = directory
        self.debounce = debounce
        self.diagnostics = diagnostics
    }

    public static func directoryName(for botID: String) -> String {
        botID.utf8.map { String(format: "%02x", $0) }.joined()
    }

    internal var writeCount: Int { state.withLock { $0.writeCount } }

    public func load(botID: String) -> ComposerDraft {
        state.withLock { draft(for: botID, in: &$0) }
    }

    public func loadDetached(botID: String) async -> ComposerDraft {
        await Task.detached { [self] in load(botID: botID) }.value
    }

    public func update(text: String, botID: String) {
        state.withLock { state in
            var draft = draft(for: botID, in: &state)
            guard draft.text != text else { return }
            draft.text = text
            state.drafts[botID] = draft
            state.pending.insert(botID)
            armTimer(in: &state)
        }
    }

    // swiftlint:disable:next function_parameter_count
    public func addAttachment(
        botID: String, id: UUID, kind: DraftAttachment.Kind, name: String, mime: String, data: Data, thumbnail: Data?
    ) throws -> DraftAttachment {
        guard data.count <= Self.maximumAttachmentBytes else { throw DraftError.tooLarge }
        return try state.withLock { state in
            var draft = draft(for: botID, in: &state)
            guard draft.attachments.count < Self.maximumAttachments else { throw DraftError.tooMany }
            let folder = botDirectory(botID)
            let stored = "\(id.uuidString)-\(Self.sanitized(name))"
            let thumbnailName = thumbnail == nil ? nil : "\(id.uuidString)-thumbnail"
            let attachment = DraftAttachment(
                id: id, kind: kind, name: name, mime: mime, stored: stored, thumbnail: thumbnailName
            )
            let fresh = !FileManager.default.fileExists(atPath: folder.path)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent(stored), options: .protectedAtomic)
                if let thumbnail, let thumbnailName {
                    try thumbnail.write(to: folder.appendingPathComponent(thumbnailName), options: .protectedAtomic)
                }
                draft.attachments.append(attachment)
                try writeManifest(draft, botID: botID, in: &state)
            } catch {
                discard(attachment, in: folder, removingFolder: fresh)
                throw error
            }
            state.drafts[botID] = draft
            state.pending.remove(botID)
            return attachment
        }
    }

    public func removeAttachment(id: UUID, botID: String) {
        state.withLock { state in
            var draft = draft(for: botID, in: &state)
            guard let removed = draft.attachments.first(where: { $0.id == id }) else { return }
            discard(removed, in: botDirectory(botID), removingFolder: false)
            draft.attachments.removeAll { $0.id == id }
            state.drafts[botID] = draft
            state.pending.remove(botID)
            persist(draft, botID: botID, in: &state)
        }
    }

    public func attachmentData(_ attachment: DraftAttachment, botID: String) -> Data? {
        contents(of: attachment.stored, botID: botID)
    }

    public func thumbnailData(_ attachment: DraftAttachment, botID: String) -> Data? {
        attachment.thumbnail.flatMap { contents(of: $0, botID: botID) }
    }

    public func flush() {
        state.withLock { state in
            state.timer?.cancel()
            state.timer = nil
            persistPending(in: &state)
        }
    }

    public func clear(botID: String) {
        state.withLock { state in
            state.pending.remove(botID)
            state.drafts[botID] = .empty
            removeFolder(botID)
        }
    }

    private func botDirectory(_ botID: String) -> URL {
        directory.appendingPathComponent(Self.directoryName(for: botID), isDirectory: true)
    }

    private func draft(for botID: String, in state: inout State) -> ComposerDraft {
        if let known = state.drafts[botID] { return known }
        let loaded = readManifest(botID)
        state.drafts[botID] = loaded
        return loaded
    }

    private func readManifest(_ botID: String) -> ComposerDraft {
        let url = botDirectory(botID).appendingPathComponent("draft.json")
        guard let data = try? Data(contentsOf: url) else { return .empty }
        do {
            return try JSONDecoder().decode(ComposerDraft.self, from: data)
        } catch {
            diagnostics.warning("drafts", "unreadable draft manifest: \(Diagnostics.describe(error))")
            return .empty
        }
    }

    private func contents(of name: String, botID: String) -> Data? {
        let folder = botDirectory(botID).standardizedFileURL
        let url = folder.appendingPathComponent(name).standardizedFileURL
        guard url.path.hasPrefix(folder.path + "/"), url.lastPathComponent != "draft.json" else { return nil }
        return try? Data(contentsOf: url)
    }

    private func armTimer(in state: inout State) {
        state.timer?.cancel()
        state.timer = Task { [self, debounce] in
            do { try await Task.sleep(for: debounce) } catch { return }
            self.state.withLock { locked in
                locked.timer = nil
                persistPending(in: &locked)
            }
        }
    }

    private func persistPending(in state: inout State) {
        for botID in state.pending {
            persist(state.drafts[botID] ?? .empty, botID: botID, in: &state)
        }
        state.pending.removeAll()
    }

    private func persist(_ draft: ComposerDraft, botID: String, in state: inout State) {
        if draft.isEmpty {
            removeFolder(botID)
            return
        }
        do {
            try FileManager.default.createDirectory(at: botDirectory(botID), withIntermediateDirectories: true)
            try writeManifest(draft, botID: botID, in: &state)
        } catch {
            diagnostics.warning("drafts", "draft not saved: \(Diagnostics.describe(error))")
        }
    }

    private func writeManifest(_ draft: ComposerDraft, botID: String, in state: inout State) throws {
        let data = try JSONEncoder().encode(draft)
        try data.write(to: botDirectory(botID).appendingPathComponent("draft.json"), options: .protectedAtomic)
        state.writeCount += 1
    }

    private func removeFolder(_ botID: String) {
        let folder = botDirectory(botID)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            diagnostics.warning("drafts", "draft folder not removed: \(Diagnostics.describe(error))")
        }
    }

    private func discard(_ attachment: DraftAttachment, in folder: URL, removingFolder: Bool) {
        if removingFolder {
            try? FileManager.default.removeItem(at: folder)
            return
        }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(attachment.stored))
        if let thumbnail = attachment.thumbnail {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(thumbnail))
        }
    }

    private static func sanitized(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "..", with: "_")
        for separator in ["/", "\\", ":", "\0"] { cleaned = cleaned.replacingOccurrences(of: separator, with: "_") }
        cleaned = String(cleaned.prefix(80))
        return cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? "file" : cleaned
    }
}
