import Foundation
import PalDiagnostics
import PalProtocol
import PalTransport

public struct OutboxEntry: Codable, Sendable, Hashable, Identifiable {
    public enum State: Codable, Sendable, Hashable {
        case pending
        case admitted(admissionID: String)
        case failed(reason: String)
    }

    public var submissionID: String
    public var botID: String
    public var text: String
    public var attachments: [PromptAttachment]
    public var files: [StoredAttachment]
    public var createdAt: Date
    public var state: State
    public var attempts: Int
    public var nextAttemptAt: Date?

    public var id: String { submissionID }

    public init(
        submissionID: String,
        botID: String,
        text: String,
        attachments: [PromptAttachment],
        files: [StoredAttachment] = [],
        createdAt: Date,
        state: State,
        attempts: Int,
        nextAttemptAt: Date? = nil
    ) {
        self.submissionID = submissionID
        self.botID = botID
        self.text = text
        self.attachments = attachments
        self.files = files
        self.createdAt = createdAt
        self.state = state
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        submissionID = try container.decode(String.self, forKey: .submissionID)
        botID = try container.decode(String.self, forKey: .botID)
        text = try container.decode(String.self, forKey: .text)
        attachments = try container.decode([PromptAttachment].self, forKey: .attachments)
        files = try container.decodeIfPresent([StoredAttachment].self, forKey: .files) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        state = try container.decode(State.self, forKey: .state)
        attempts = try container.decode(Int.self, forKey: .attempts)
        nextAttemptAt = try container.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
    }
}

public protocol OutboxSubmitter: Sendable {
    func submit(_ entry: OutboxEntry, files: [OutgoingFile]) async throws -> AdmissionStatus
}

public enum DeliveryResult: Sendable, Equatable {
    case admitted(AdmissionStatus)
    case failed(reason: String)
    case retryLater
    case alreadyDone
    case inFlight
    case unknownEntry
}

public struct OutboxStore: Sendable {
    private struct File: Codable {
        var version: Int
        var entries: [OutboxEntry]
    }

    public let fileURL: URL
    private let lockURL: URL
    private let diagnostics: Diagnostics

    public init(directory: URL, diagnostics: Diagnostics = .silent) {
        fileURL = directory.appendingPathComponent("outbox.json")
        lockURL = directory.appendingPathComponent("outbox.lock")
        self.diagnostics = diagnostics
    }

    public func load() throws -> [OutboxEntry] {
        try locked { try readUnlocked() }
    }

    public func save(_ entries: [OutboxEntry]) throws {
        try locked { try writeUnlocked(entries) }
    }

    func update<Result>(_ body: (inout [OutboxEntry]) throws -> Result) throws -> (entries: [OutboxEntry], result: Result) {
        try locked {
            var entries = try readUnlocked()
            let result = try body(&entries)
            try writeUnlocked(entries)
            return (entries, result)
        }
    }

    private func locked<Result>(_ body: () throws -> Result) throws -> Result {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw CocoaError(.fileLocking) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func readUnlocked() throws -> [OutboxEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        do {
            return try Self.decoder.decode(File.self, from: data).entries
        } catch {
            let quarantine = fileURL.deletingLastPathComponent()
                .appendingPathComponent("outbox.corrupt-\(UUID().uuidString).json")
            try FileManager.default.moveItem(at: fileURL, to: quarantine)
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let count = (object?["entries"] as? [Any])?.count ?? 0
            diagnostics.warning("outbox", "outbox file quarantined; entries=\(count)")
            return []
        }
    }

    private func writeUnlocked(_ entries: [OutboxEntry]) throws {
        let data = try Self.encoder.encode(File(version: 1, entries: entries))
        try data.write(to: fileURL, options: Self.writeOptions)
    }

    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

public actor Outbox {
    private let store: OutboxStore
    private let fileStore: AttachmentStore
    private let submitter: any OutboxSubmitter
    private let diagnostics: Diagnostics
    private let now: @Sendable () -> Date
    private var entries: [OutboxEntry]
    private var inFlight: Set<String> = []

    public init(
        directory: URL,
        submitter: any OutboxSubmitter,
        diagnostics: Diagnostics = .silent,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        store = OutboxStore(directory: directory, diagnostics: diagnostics)
        fileStore = AttachmentStore(directory: directory)
        self.submitter = submitter
        self.diagnostics = diagnostics
        self.now = now
        entries = try store.load()
        fileStore.sweep(keeping: Set(entries.map(\.submissionID)))
    }

    public static let attachmentUnreadable = "attachment_unreadable"

    public static func backoff(afterAttempts attempts: Int) -> TimeInterval {
        min(300, 2 * pow(2, Double(max(attempts, 1) - 1)))
    }

    public func enqueue(
        botID: String,
        text: String,
        attachments: [PromptAttachment] = [],
        files: [OutgoingFile] = []
    ) throws -> OutboxEntry {
        let submissionID = UUID().uuidString
        let saved = try fileStore.save(files, submissionID: submissionID)
        let entry = OutboxEntry(
            submissionID: submissionID,
            botID: botID,
            text: text,
            attachments: attachments,
            files: saved,
            createdAt: Date(),
            state: .pending,
            attempts: 0
        )
        do {
            entries = try store.update { $0.append(entry) }.entries
        } catch {
            fileStore.remove(submissionID: submissionID)
            throw error
        }
        return entry
    }

    public func requeue(_ failed: OutboxEntry) throws -> OutboxEntry {
        try enqueue(
            botID: failed.botID,
            text: failed.text,
            attachments: failed.attachments,
            files: try fileStore.load(failed.files)
        )
    }

    public func snapshot(botID: String? = nil) -> [OutboxEntry] {
        refresh()
        return entries.filter { botID == nil || $0.botID == botID }
    }

    public func pending(botID: String? = nil) -> [OutboxEntry] {
        snapshot(botID: botID).filter { $0.state == .pending }
    }

    public func deliver(_ submissionID: String) async -> DeliveryResult {
        refresh()
        guard let entry = entries.first(where: { $0.submissionID == submissionID }) else { return .unknownEntry }
        guard entry.state == .pending else { return .alreadyDone }
        guard inFlight.insert(submissionID).inserted else { return .inFlight }
        defer { inFlight.remove(submissionID) }
        let files: [OutgoingFile]
        do {
            files = try fileStore.load(entry.files)
        } catch {
            diagnostics.warning("outbox", "attachments are no longer readable: \(Diagnostics.describe(error))")
            record(submissionID, state: .failed(reason: Self.attachmentUnreadable))
            return .failed(reason: Self.attachmentUnreadable)
        }
        do {
            let status = try await submitter.submit(entry, files: files)
            record(submissionID, state: .admitted(admissionID: status.admissionID))
            fileStore.remove(submissionID: submissionID)
            return .admitted(status)
        } catch {
            if let refusal = RefusalReason(error), refusal.isPermanent {
                diagnostics.warning("outbox", "submission refused: reason=\(refusal.reason)")
                record(submissionID, state: .failed(reason: refusal.reason))
                return .failed(reason: refusal.reason)
            }
            diagnostics.info("outbox", "delivery will retry: \(Diagnostics.describe(error))")
            scheduleRetry(submissionID)
            return .retryLater
        }
    }

    public func deliverPending(botID: String? = nil) async -> [DeliveryResult] {
        var results: [DeliveryResult] = []
        for entry in pending(botID: botID) {
            if let due = entry.nextAttemptAt, due > now() { break }
            let result = await deliver(entry.submissionID)
            results.append(result)
            if result == .retryLater { break }
        }
        return results
    }

    public func cancel(_ submissionID: String) throws {
        entries = try store.update { stored in
            stored.removeAll { $0.submissionID == submissionID && $0.state == .pending }
        }.entries
        fileStore.remove(submissionID: submissionID)
    }

    public func purgeFinished() throws {
        let removed = entries.filter { $0.state != .pending }.map(\.submissionID)
        entries = try store.update { $0.removeAll { $0.state != .pending } }.entries
        for submissionID in removed { fileStore.remove(submissionID: submissionID) }
    }

    private func refresh() {
        do {
            entries = try store.load()
        } catch {
            diagnostics.error("outbox", "could not read outbox: \(Diagnostics.describe(error))")
        }
    }

    private func record(_ submissionID: String, state: OutboxEntry.State) {
        mutate(submissionID) { entry in
            entry.state = state
            entry.attempts += 1
            entry.nextAttemptAt = nil
        }
    }

    private func scheduleRetry(_ submissionID: String) {
        let base = now()
        mutate(submissionID) { entry in
            entry.attempts += 1
            entry.nextAttemptAt = base.addingTimeInterval(Self.backoff(afterAttempts: entry.attempts))
        }
    }

    private func mutate(_ submissionID: String, _ change: (inout OutboxEntry) -> Void) {
        do {
            entries = try store.update { stored in
                guard let index = stored.firstIndex(where: { $0.submissionID == submissionID }),
                      stored[index].state == .pending
                else { return }
                change(&stored[index])
            }.entries
        } catch {
            diagnostics.error("outbox", "could not persist outbox: \(Diagnostics.describe(error))")
        }
    }
}

public struct BotChatSubmitter: OutboxSubmitter {
    private let connector: any ChatConnector
    private let diagnostics: Diagnostics

    public init(connector: any ChatConnector, diagnostics: Diagnostics = .silent) {
        self.connector = connector
        self.diagnostics = diagnostics
    }

    public func submit(_ entry: OutboxEntry, files: [OutgoingFile]) async throws -> AdmissionStatus {
        let connection = try await connector.connect()
        let api = SessionAPI(connection: connection, profile: entry.botID)
        do {
            let resolution = try await BotChatResolver(diagnostics: diagnostics).open(api)
            let status = try await api.submit(
                sessionID: resolution.snapshot.sessionID,
                text: entry.text,
                submissionID: entry.submissionID,
                attachments: entry.attachments,
                files: files
            )
            await connection.close()
            return status
        } catch {
            await connection.close()
            throw error
        }
    }
}
