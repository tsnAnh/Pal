import Foundation
import PalBotProfile
import PalChat
import PalProtocol
import Observation

struct RoomUpload: Identifiable, Equatable {
    let id: UUID
    let name: String
    let thumbnail: Data?
    let isImage: Bool
    var stored: RoomAttachment?
    var failure: String?

    var isUploading: Bool { stored == nil && failure == nil }

    var pending: PendingAttachment {
        let state: PendingAttachment.State = if let failure {
            .failed(reason: failure)
        } else if stored != nil {
            .ready(.file(referenceText: ""))
        } else {
            .uploading
        }
        return PendingAttachment(id: id, kind: isImage ? .image : .file, name: name, thumbnail: thumbnail, state: state)
    }
}

@MainActor
@Observable
final class RoomModel {
    static let pollInterval: Duration = .seconds(2)

    private(set) var room: Room
    private(set) var log = RoomLog()
    private(set) var driver: RoomDriver?
    private(set) var isLoaded = false
    private(set) var isUnreachable = false
    private(set) var isStopping = false
    private(set) var uploads: [RoomUpload] = []
    private(set) var busyActions: Set<String> = []
    var pendingDraft: String?
    var failure: String?

    let roomID: String
    private let service: RoomsService
    private let rooms: RoomsModel
    private var capabilities: RoomCapabilities?
    private var refreshing = false
    private var attempt: SendAttempt?

    private struct SendAttempt {
        let eventID: String
        let text: String
        let attachmentIDs: [String]
    }

    init(room: Room, service: RoomsService, rooms: RoomsModel) {
        self.room = room
        roomID = room.roomID
        self.service = service
        self.rooms = rooms
        capabilities = rooms.capabilities
        log = rooms.surfaces.remembered(RoomLog.self, .screen("room-log-\(room.roomID)")) ?? RoomLog()
    }

    var events: [RoomEvent] { log.events }
    var isBusy: Bool { driver?.isBusy ?? false }
    var pendingActions: [RoomPendingAction] { driver?.pendingActions ?? [] }
    var canRename: Bool { capabilities?.offers("groups.rename") ?? true }
    var canUpload: Bool { capabilities?.offers("groups.attachment.upload") ?? true }
    var canDownload: Bool { capabilities?.offers("groups.attachment.download") ?? true }
    var canStop: Bool { isBusy && !isStopping && (capabilities?.offers("groups.stop") ?? true) }
    var isUploading: Bool { uploads.contains(where: \.isUploading) }
    var hasFailedUpload: Bool { uploads.contains { $0.failure != nil } }

    var canSend: Bool { !isUploading && !hasFailedUpload && !isStopping }

    var pendingAttachments: [PendingAttachment] { uploads.map(\.pending) }

    func busyMemberIDs() -> Set<String> { Set(driver?.busyMembers ?? []) }

    func run() async {
        if capabilities == nil { capabilities = try? await service.capabilities() }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let result = try await service.refresh(roomID: roomID, log: log)
            log.apply(room: result.snapshot.room, since: result.since, events: result.events)
            rooms.surfaces.remember(log, .screen("room-log-\(roomID)"))
            room = result.snapshot.room
            driver = result.snapshot.driver
            rooms.apply(result.snapshot.room)
            if driver?.isBusy != true { isStopping = false }
            isUnreachable = false
            isLoaded = true
        } catch is CancellationError {
            return
        } catch {
            isUnreachable = true
        }
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = uploads.compactMap(\.stored)
        guard canSend, !trimmed.isEmpty || !attachments.isEmpty else { return }
        let ids = attachments.map(\.attachmentID)
        let current: SendAttempt
        if let attempt, attempt.text == trimmed, attempt.attachmentIDs == ids {
            current = attempt
        } else {
            current = SendAttempt(eventID: UUID().uuidString.lowercased(), text: trimmed, attachmentIDs: ids)
        }
        attempt = current
        uploads = []
        Task {
            do {
                try await service.send(roomID: roomID, eventID: current.eventID, text: trimmed, attachments: attachments)
                attempt = nil
                await refresh()
            } catch {
                failure = String(localized: "Your message wasn't sent. It's back in the box so you can send it again.")
                pendingDraft = trimmed
                restore(attachments)
            }
        }
    }

    func stop() {
        guard canStop else { return }
        isStopping = true
        Task {
            do {
                try await service.stop(roomID: roomID, cancelID: UUID().uuidString.lowercased())
                await refresh()
            } catch {
                isStopping = false
                failure = String(localized: "The bots couldn't be stopped. Try again.")
            }
        }
    }

    func rename(to name: String) async -> Bool {
        do {
            let renamed = try await service.rename(roomID: roomID, eventID: UUID().uuidString.lowercased(), name: name)
            room = renamed
            rooms.apply(renamed)
            return true
        } catch RoomError.invalidName {
            failure = String(localized: "Choose a name up to 120 characters.")
        } catch {
            failure = String(localized: "The group chat couldn't be renamed. Try again.")
        }
        return false
    }

    func approve(_ action: RoomPendingAction, allow: Bool) { act(action) { try await $0.approve(roomID: $1, action: action, allow: allow) } }
    func retry(_ action: RoomPendingAction) { act(action) { try await $0.retry(roomID: $1, action: action) } }
    func discard(_ action: RoomPendingAction) { act(action) { try await $0.discard(roomID: $1, action: action) } }

    private func act(_ action: RoomPendingAction, _ run: @escaping @Sendable (RoomsService, String) async throws -> Void) {
        guard busyActions.insert(action.id).inserted else { return }
        Task {
            defer { busyActions.remove(action.id) }
            do {
                try await run(service, roomID)
                await refresh()
            } catch {
                failure = String(localized: "That didn't go through. The request may no longer be waiting.")
                await refresh()
            }
        }
    }

    func attach(_ upload: PreparedUpload, mime: String) {
        guard canUpload else {
            failure = String(localized: "This group chat can't take attachments.")
            return
        }
        let id = UUID()
        uploads.append(RoomUpload(id: id, name: upload.filename, thumbnail: upload.thumbnail, isImage: RoomsService.kind(forMime: mime) == "image"))
        Task {
            do {
                let stored = try await service.upload(
                    roomID: roomID, uploadID: id.uuidString.lowercased(), data: upload.data, name: upload.filename, mime: mime
                )
                update(id) { $0.stored = stored }
            } catch RoomError.attachmentTooLarge {
                update(id) { $0.failure = String(localized: "That file is too large to send.") }
            } catch {
                update(id) { $0.failure = String(localized: "That file couldn't be uploaded.") }
            }
        }
    }

    func removeUpload(_ id: UUID) {
        uploads.removeAll { $0.id == id }
    }

    func reportAttachmentFailure(_ message: String) {
        failure = message
    }

    func download(_ attachment: RoomAttachment, in event: RoomEvent) async -> Data? {
        do {
            return try await service.download(roomID: roomID, eventID: event.eventID, attachment: attachment)
        } catch {
            failure = String(localized: "That file couldn't be downloaded.")
            return nil
        }
    }

    func dismissFailure() { failure = nil }

    func clearPendingDraft() { pendingDraft = nil }

    private func update(_ id: UUID, _ change: (inout RoomUpload) -> Void) {
        guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
        change(&uploads[index])
    }

    private func restore(_ attachments: [RoomAttachment]) {
        uploads = attachments.map {
            RoomUpload(id: UUID(), name: $0.name, thumbnail: nil, isImage: $0.kind == "image", stored: $0)
        }
    }
}
