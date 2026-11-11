import Foundation
import HermesProtocol
import Observation

@MainActor
@Observable
public final class SpeechMemoryModel {
    public enum Work: Sendable, Equatable {
        case choosing
        case removing
    }

    public enum RowStatus: Sendable, Equatable {
        case idle
        case working(Work)
        case succeeded(String)
        case failed(String)
    }

    public enum KeyEntryState: Sendable, Equatable {
        case idle
        case submitting
        case failed(String)
    }

    public struct Target: Sendable, Equatable, Identifiable {
        public let area: SpeechMemoryArea
        public let provider: SpeechMemoryProvider
        public var id: String { SpeechMemoryModel.rowID(area, provider.id) }
    }

    public private(set) var settings: SpeechMemorySettings?
    public private(set) var isLoading = false
    public private(set) var loadFailed = false
    public private(set) var rows: [String: RowStatus] = [:]
    public private(set) var choices: [SpeechMemoryArea: RowStatus] = [:]
    public private(set) var keyEntryState: KeyEntryState = .idle
    public var keyEntry: Target?
    public var pendingRemoval: Target?

    @ObservationIgnored private let client: SpeechMemoryClient

    public init(client: SpeechMemoryClient) {
        self.client = client
    }

    public nonisolated static func rowID(_ area: SpeechMemoryArea, _ provider: String) -> String { "\(area.rawValue):\(provider)" }

    public var hasLoaded: Bool { settings != nil }

    public func status(_ area: SpeechMemoryArea, _ provider: String) -> RowStatus { rows[Self.rowID(area, provider)] ?? .idle }

    public func isWorking(_ area: SpeechMemoryArea, _ provider: String) -> Bool {
        if case .working = status(area, provider) { true } else { false }
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            settings = try await client.settings()
            loadFailed = false
        } catch is CancellationError {
        } catch {
            loadFailed = true
        }
    }

    public func choice(_ area: SpeechMemoryArea) -> RowStatus { choices[area] ?? .idle }

    public func choose(_ area: SpeechMemoryArea, provider: String, voice: String? = nil) async {
        guard settings?.group(area).selected != provider || voice != nil, choice(area) != .working(.choosing) else { return }
        choices[area] = .working(.choosing)
        switch await client.choose(area, provider: provider, voice: voice) {
        case .saved(let updated):
            if let updated { settings = updated } else { await refresh() }
            choices[area] = .succeeded("Saved. Applies to new chats.")
        case .needsKey(let reason), .unsupported(let reason), .invalid(let reason), .failed(let reason):
            choices[area] = .failed(reason)
        }
    }

    public func beginKeyEntry(_ target: Target) {
        guard target.provider.keyName != nil else { return }
        keyEntryState = .idle
        keyEntry = target
    }

    public func cancelKeyEntry() {
        keyEntry = nil
        keyEntryState = .idle
    }

    public func submitKey(_ value: String) async {
        guard let target = keyEntry, let keyName = target.provider.keyName, keyEntryState != .submitting else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keyEntryState = .failed("Paste a key to save.")
            return
        }
        keyEntryState = .submitting
        do {
            try await client.setKey(keyName, to: SecretString(trimmed))
        } catch is CancellationError {
            keyEntryState = .idle
            return
        } catch {
            keyEntryState = .failed("Couldn't save the key. Check it and try again.")
            return
        }
        await refresh()
        set(target.area, target.provider.id, .succeeded("Key saved."))
        cancelKeyEntry()
    }

    public func remove(_ target: Target) async {
        pendingRemoval = nil
        guard target.provider.canRemove, let keyName = target.provider.keyName, !isWorking(target.area, target.provider.id) else { return }
        set(target.area, target.provider.id, .working(.removing))
        do {
            try await client.removeKey(keyName)
        } catch {
            await refresh()
            set(target.area, target.provider.id, .failed("Couldn't remove the key. It was kept."))
            return
        }
        await refresh()
        let stillSet = settings?.group(target.area).providers.first { $0.id == target.provider.id }?.keySet ?? false
        set(
            target.area, target.provider.id,
            stillSet ? .failed("Another source still supplies a key, such as your model provider's.") : .succeeded("Key removed."))
    }

    private func set(_ area: SpeechMemoryArea, _ provider: String, _ status: RowStatus) {
        rows[Self.rowID(area, provider)] = status
    }

    private func refresh() async {
        guard let fresh = try? await client.settings() else { return }
        settings = fresh
        loadFailed = false
    }
}
