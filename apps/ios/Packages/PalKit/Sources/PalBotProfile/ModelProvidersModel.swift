import Foundation
import PalProtocol
import Observation

@MainActor
@Observable
public final class ModelProvidersModel {
    public enum Work: Sendable, Equatable {
        case signingIn
        case removing
        case savingAddress
    }

    public enum RowStatus: Sendable, Equatable {
        case idle
        case working(Work)
        case succeeded(String)
        case failed(String)
        case cancelled
    }

    private struct PendingSignIn {
        let requestID: String?
    }

    public private(set) var providers: [ModelProvider] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var loadFailed = false
    public private(set) var rows: [String: RowStatus] = [:]
    public var pendingRemoval: ModelProvider?

    private var drafts: [String: String] = [:]
    private var signIns: [String: PendingSignIn] = [:]
    @ObservationIgnored private let client: ModelProvidersClient

    public init(client: ModelProvidersClient) {
        self.client = client
    }

    public func status(of id: String) -> RowStatus { rows[id] ?? .idle }

    public func isWorking(_ id: String) -> Bool {
        if case .working = status(of: id) { true } else { false }
    }

    public func address(for provider: ModelProvider) -> String { drafts[provider.id] ?? provider.baseURL ?? "" }

    public func setAddress(_ text: String, for provider: ModelProvider) {
        drafts[provider.id] = text
    }

    public func addressIsDirty(for provider: ModelProvider) -> Bool {
        guard let draft = drafts[provider.id] else { return false }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines) != (provider.baseURL ?? "")
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            providers = try await client.list()
            loadFailed = false
            hasLoaded = true
        } catch is CancellationError {
        } catch {
            loadFailed = true
        }
    }

    public func signIn(_ provider: ModelProvider) async {
        guard provider.canSignIn, !isWorking(provider.id) else { return }
        rows[provider.id] = .working(.signingIn)
        switch await client.beginSignIn(provider.id) {
        case .started(let requestID):
            signIns[provider.id] = PendingSignIn(requestID: requestID)
        case .unsupported(let reason), .refused(let reason), .unavailable(let reason):
            rows[provider.id] = .failed(reason)
        }
    }

    public func signInResolved(requestID: String, service: String?, outcome: ServiceSignInOutcome, reason: String?) async {
        guard let id = pendingProvider(requestID: requestID, service: service) else { return }
        signIns[id] = nil
        let kind = providers.first { $0.id == id }?.kind
        switch outcome {
        case .signedIn:
            await refresh()
            rows[id] = .succeeded(kind == .deviceCode ? "Signed in." : "Key saved.")
        case .declined:
            rows[id] = .cancelled
        case .timedOut:
            await refresh()
            rows[id] = .failed("Sign-in took too long. Try again.")
        case .failed, .unknown:
            await refresh()
            rows[id] = .failed(reason ?? "Sign-in didn't finish. Try again.")
        }
    }

    public func remove(_ provider: ModelProvider) async {
        pendingRemoval = nil
        guard provider.canRemove else { return }
        guard !isWorking(provider.id) else { return }
        rows[provider.id] = .working(.removing)
        switch await client.remove(provider.id) {
        case .removed(let updated):
            await apply(updated)
            rows[provider.id] = .succeeded("Removed.")
        case .nothingToRemove(let updated):
            await apply(updated)
            rows[provider.id] = .succeeded("There was nothing to remove.")
        case .stillSet(let reason, let updated):
            await apply(updated)
            rows[provider.id] = .failed(reason)
        case .refused(let reason), .unsupported(let reason), .failed(let reason):
            rows[provider.id] = .failed(reason)
        }
    }

    public func saveAddress(_ provider: ModelProvider) async {
        let text = address(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            rows[provider.id] = .failed("Enter an address, or use the default.")
            return
        }
        await changeAddress(provider, to: text)
    }

    public func useDefaultAddress(_ provider: ModelProvider) async {
        await changeAddress(provider, to: nil)
    }

    private func changeAddress(_ provider: ModelProvider, to address: String?) async {
        guard !isWorking(provider.id) else { return }
        rows[provider.id] = .working(.savingAddress)
        switch await client.setBaseURL(provider.id, to: address) {
        case .saved(let updated):
            drafts[provider.id] = nil
            await apply(updated)
            rows[provider.id] = .succeeded("Address saved.")
        case .reset(let updated):
            drafts[provider.id] = nil
            await apply(updated)
            rows[provider.id] = .succeeded("Using the default address.")
        case .invalid(let reason), .unsupported(let reason), .failed(let reason):
            rows[provider.id] = .failed(reason)
        }
    }

    private func pendingProvider(requestID: String, service: String?) -> String? {
        if let match = signIns.first(where: { $0.value.requestID == requestID }) { return match.key }
        guard let service, service.hasPrefix(ModelProvidersClient.serviceKey) else { return nil }
        let id = String(service.dropFirst(ModelProvidersClient.serviceKey.count))
        return signIns[id] == nil ? nil : id
    }

    private func apply(_ updated: ModelProvider?) async {
        if let updated {
            replace(updated)
        } else {
            await refresh()
        }
    }

    private func refresh() async {
        guard let fresh = try? await client.list() else { return }
        providers = fresh
        loadFailed = false
    }

    private func replace(_ provider: ModelProvider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
    }
}
