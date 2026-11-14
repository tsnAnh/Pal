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

    public private(set) var providers: [ModelProvider] = [] {
        didSet { surfaces.remember(providers, Self.surfaceKey) }
    }
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var loadFailed = false
    public private(set) var rows: [String: RowStatus] = [:]
    public var pendingRemoval: ModelProvider?
    public var query = ""
    public var showsAllOnHost = false

    private var drafts: [String: String] = [:]
    private var signIns: [String: PendingSignIn] = [:]
    @ObservationIgnored private let client: ModelProvidersClient
    @ObservationIgnored private let surfaces: SurfaceCache
    private static let surfaceKey = SurfaceKey.screen("model-providers")

    public init(client: ModelProvidersClient, surfaces: SurfaceCache) {
        self.client = client
        self.surfaces = surfaces
        if let held = surfaces.remembered([ModelProvider].self, Self.surfaceKey) {
            providers = held
            hasLoaded = true
        }
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
            rows[id] = .succeeded(Self.signedInText(id: id, kind: kind))
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

    private static func signedInText(id: String, kind: ModelProviderKind?) -> String {
        if ModelProviderCredential.setupTokenProviders.contains(id) { return "Saved." }
        return kind == .deviceCode || kind == .oauthPaste ? "Signed in." : "Key saved."
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

public enum ModelProviderGroup: String, CaseIterable, Sendable {
    case connected
    case available
    case onHost

    public var title: String {
        switch self {
        case .connected: "Connected"
        case .available: "Add a provider"
        case .onHost: "Set up on the computer that runs Pal"
        }
    }
}

public struct ModelProviderSection: Identifiable, Equatable, Sendable {
    public let group: ModelProviderGroup
    public let providers: [ModelProvider]
    public let hiddenCount: Int

    public var id: ModelProviderGroup { group }
}

public struct ModelProviderFace: Equatable, Sendable {
    public let stateLabel: String?
    public let detail: String?
    public let primaryAction: String?
    public let canRemove: Bool
    public let canEditAddress: Bool
    public let isAttention: Bool
    public let status: ModelProvidersModel.RowStatus
}

extension ModelProvider {
    public var group: ModelProviderGroup {
        switch (kind, state) {
        case (.unsupported, _), (.unknown, _), (_, .unsupported): .onHost
        case (_, .set), (_, .expired): .connected
        case (_, .notSet), (_, .unknown): .available
        }
    }
}

extension ModelProvidersModel {
    public static let emptyConnectedText = "No providers connected yet. Add one below."
    public static let noMatchText = "No providers match."
    public static let footnoteText = "Keys and tokens are saved on the computer that runs Pal and never shown again."
    public static let loadFailureText = "Couldn't load your model providers."
    public static let refreshFailureText = "Couldn't refresh. Try again."

    public var sections: [ModelProviderSection] {
        ModelProviderSorting.sections(providers, query: query, showsAllOnHost: showsAllOnHost)
    }

    public func presentation(of provider: ModelProvider) -> ModelProviderFace {
        ModelProviderSorting.face(provider, status: status(of: provider.id))
    }
}

enum ModelProviderSorting {
    private static let collapsedOnHostCount = 1

    static func sections(_ providers: [ModelProvider], query: String, showsAllOnHost: Bool) -> [ModelProviderSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty ? providers : providers.filter { matches($0, needle) }
        return ModelProviderGroup.allCases.compactMap { group in
            let members = ordered(matching.filter { $0.group == group }, in: group)
            guard !members.isEmpty || (group == .connected && needle.isEmpty) else { return nil }
            guard group == .onHost, needle.isEmpty, !showsAllOnHost, members.count > collapsedOnHostCount else {
                return ModelProviderSection(group: group, providers: members, hiddenCount: 0)
            }
            return ModelProviderSection(
                group: group, providers: Array(members.prefix(collapsedOnHostCount)), hiddenCount: members.count - collapsedOnHostCount)
        }
    }

    static func face(_ provider: ModelProvider, status: ModelProvidersModel.RowStatus) -> ModelProviderFace {
        let group = provider.group
        let base = statusText(status) ?? stateDetail(provider, group: group)
        let shared = provider.scope == .account && group != .onHost && status == .idle ? sharedText : nil
        var failed = false
        if case .failed = status { failed = true }
        return ModelProviderFace(
            stateLabel: provider.state == .expired ? "Expired" : nil,
            detail: [base, shared].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
            primaryAction: primaryAction(provider, status: status),
            canRemove: provider.canRemove,
            canEditAddress: provider.baseURLEditable && group == .connected,
            isAttention: provider.state == .expired || failed,
            status: status
        )
    }

    private static let sharedText = "Shared by all your bots"

    private static func matches(_ provider: ModelProvider, _ needle: String) -> Bool {
        provider.name.localizedStandardContains(needle) || provider.id.localizedStandardContains(needle)
    }

    private static func ordered(_ providers: [ModelProvider], in group: ModelProviderGroup) -> [ModelProvider] {
        providers.sorted { lhs, rhs in
            if group == .connected, (lhs.state == .expired) != (rhs.state == .expired) { return lhs.state == .expired }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func statusText(_ status: ModelProvidersModel.RowStatus) -> String? {
        switch status {
        case .idle: nil
        case .working(.signingIn): "Waiting for you to finish signing in…"
        case .working(.removing): "Removing…"
        case .working(.savingAddress): "Saving…"
        case .succeeded(let text), .failed(let text): text
        case .cancelled: "Cancelled. Nothing changed."
        }
    }

    private static func stateDetail(_ provider: ModelProvider, group: ModelProviderGroup) -> String? {
        if provider.state == .expired { return provider.reason ?? "Expired. Sign in again to keep using it." }
        switch group {
        case .onHost: return provider.reason
        case .connected:
            if provider.acceptsSetupToken { return "API key or Claude plan token saved" }
            return provider.kind == .apiKey ? "API key saved" : "Signed in"
        case .available:
            return provider.acceptsSetupToken ? "API key, or your Claude Pro or Max plan with a setup token" : nil
        }
    }

    private static func primaryAction(_ provider: ModelProvider, status: ModelProvidersModel.RowStatus) -> String? {
        guard provider.canSignIn else { return nil }
        if status == .working(.signingIn) { return "Waiting…" }
        let isSet = provider.state == .set || provider.state == .expired
        switch provider.kind {
        case .apiKey:
            if provider.acceptsSetupToken { return isSet ? "Replace" : "Add key or token" }
            return isSet ? "Replace key" : "Add key"
        case .deviceCode, .oauthPaste:
            return isSet ? "Sign in again" : "Sign in"
        case .unsupported, .unknown:
            return nil
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
