import Foundation
import Observation
import PalProtocol

public struct ChatInstallAdvance: Sendable, Hashable {
    public var event: ChatSetupEventKind
    public var expectedRevision: Int
    public var manualStep: ChatProviderCapability?
    public var vaultItemId: String?

    public init(event: ChatSetupEventKind, expectedRevision: Int, manualStep: ChatProviderCapability? = nil, vaultItemId: String? = nil) {
        self.event = event
        self.expectedRevision = expectedRevision
        self.manualStep = manualStep
        self.vaultItemId = vaultItemId
    }
}

public struct ChatInstallScope: Sendable, Hashable {
    public var provider: String
    public var workspace: String

    public init(provider: String, workspace: String) {
        self.provider = provider
        self.workspace = workspace
    }
}

public enum ChatInstallClientError: Error, Sendable, Equatable {
    case unsupported
    case staleRevision
    case offline
    case failed
}

public protocol ChatInstallClient: Sendable {
    func providers() async throws -> [ChatCapabilitiesWire]
    func status(_ scope: ChatInstallScope) async throws -> ChatInstallStatusResult
    func begin(_ scope: ChatInstallScope) async throws
    func advance(_ scope: ChatInstallScope, _ advance: ChatInstallAdvance) async throws
    func spaces(_ scope: ChatInstallScope) async throws -> [ChatSpaceRefWire]
    func join(_ scope: ChatInstallScope, spaceId: String) async throws -> ChatSpaceJoinResult
    func bindings(_ scope: ChatInstallScope) async throws -> [ChatBindingWire]
    func revoke(_ scope: ChatInstallScope) async throws
    func storeSecret(label: String, value: String) async throws -> String
}

public enum ChatInstallScreen: Hashable, Sendable {
    case loading
    case unavailable
    case unsupported
    case providers
    case intro(again: Bool)
    case credential
    case setup(task: ChatProviderCapability?)
    case allow(URL?)
    case ready
    case error(ChatSetupErrorCode, fix: ChatFixAction)
}

public enum ChatInstallAction: Hashable, Sendable {
    case reload
    case begin
    case saveCredential
    case markDone(ChatProviderCapability)
    case openLink(URL)
    case copy(String)
    case openAllow(URL)
    case checkAgain
    case copyAdminMessage
    case fix(ChatFixAction)
    case disconnect
}

public enum ChatInstallNotice: Hashable, Sendable {
    case offline
    case notSaved
}

public enum ChatCredentialKind: Hashable, Sendable {
    case configAccess
    case configRefresh
    case appLevel

    private static let prefixes: [(String, ChatCredentialKind)] = [
        ("xoxe.xoxp-", .configAccess), ("xoxe-", .configRefresh), ("xapp-", .appLevel),
    ]

    public static func classify(_ text: String) -> ChatCredentialKind? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16, !trimmed.contains(where: \.isWhitespace) else { return nil }
        return prefixes.first { trimmed.hasPrefix($0.0) }?.1
    }
}

public struct ChatSetupChecklistItem: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case workspace, createApp, manual(ChatProviderCapability), allow, install
    }

    public enum Status: Hashable, Sendable { case done, active, pending }

    public var kind: Kind
    public var status: Status
    public var id: Kind { kind }
}

public enum ChatSpaceStatus: Hashable, Sendable {
    case available, needsInvite, joining, live
}

public struct ChatSpaceRow: Hashable, Sendable, Identifiable {
    public var space: ChatSpaceRefWire
    public var status: ChatSpaceStatus
    public var invite: ChatNextActionWire?
    public var id: String { space.id }
}

public struct ChatIdentityPreview: Hashable, Sendable {
    public var displayName: String
    public var username: String

    public init(name: String, policy: ChatIdentityPolicyWire) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = String(trimmed.prefix(policy.displayNameMax))
        let slug = trimmed.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }
            .joined()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        username = String(slug.prefix(policy.usernameMax)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

@MainActor
@Observable
public final class ChatInstallModel {
    public static let guidedSteps: [ChatProviderCapability] = [.setIcon, .appLevelCredential, .gatewayRedirect]

    public private(set) var providers: [ChatCapabilitiesWire] = []
    public private(set) var provider: ChatCapabilitiesWire?
    public private(set) var snapshot: ChatInstallStatusResult?
    public private(set) var spaces: [ChatSpaceRow] = []
    public private(set) var isWorking = false
    public private(set) var notice: ChatInstallNotice?
    private var loadFailed = false
    private var unsupported = false
    private var invites: [String: ChatNextActionWire] = [:]

    public let botName: String
    private let preferredProvider: String?
    private let client: any ChatInstallClient

    public init(botName: String, preferredProvider: String?, client: any ChatInstallClient) {
        self.botName = botName
        self.preferredProvider = preferredProvider
        self.client = client
    }

    public var state: ChatSetupStateWire? { snapshot?.state }

    public var screen: ChatInstallScreen {
        if unsupported { return .unsupported }
        guard provider != nil else {
            if loadFailed { return .unavailable }
            return providers.isEmpty ? .loading : .providers
        }
        guard let state else { return loadFailed ? .unavailable : .loading }
        switch state.step {
        case .notStarted: return .intro(again: false)
        case .revoked: return .intro(again: true)
        case .needsCredential: return .credential
        case .creatingApp, .installing: return .setup(task: nil)
        case .needsManualStep: return .setup(task: pendingTask)
        case .needsAllow: return .allow(state.nextAction.link.flatMap(URL.init(string:)))
        case .ready: return .ready
        case .error:
            guard let error = state.error else { return .unavailable }
            return .error(error.code, fix: error.fix)
        case .unknown: return .unavailable
        }
    }

    public var primaryAction: ChatInstallAction? {
        switch screen {
        case .loading, .providers, .ready: nil
        case .unavailable: .reload
        case .unsupported: nil
        case .intro: .begin
        case .credential: .saveCredential
        case .setup(let task): task.map(ChatInstallAction.markDone)
        case .allow(let url): url.map(ChatInstallAction.openAllow) ?? .checkAgain
        case .error(_, let fix): .fix(fix)
        }
    }

    public var secondaryActions: [ChatInstallAction] {
        switch screen {
        case .setup(.some):
            guard let action = state?.nextAction else { return [] }
            return [action.link.flatMap(URL.init(string:)).map(ChatInstallAction.openLink), action.copyText.map(ChatInstallAction.copy)]
                .compactMap { $0 }
        case .allow(.some): return [.checkAgain, .copyAdminMessage]
        case .ready: return [.disconnect]
        default: return []
        }
    }

    public var checklist: [ChatSetupChecklistItem] {
        guard let provider, let state else { return [] }
        let guided = Self.guidedSteps.filter { step in provider.capabilities.contains { $0.capability == step && $0.mode == .guided } }
        var kinds: [ChatSetupChecklistItem.Kind] = []
        if provider.requiresConfigCredential { kinds.append(.workspace) }
        if provider.createsApp { kinds.append(.createApp) }
        kinds += guided.map { .manual($0) }
        kinds += [.allow, .install]
        let current = activeKind(state)
        let currentIndex = current.flatMap(kinds.firstIndex(of:)) ?? (state.step == .ready ? kinds.count : 0)
        return kinds.enumerated().map { index, kind in
            let status: ChatSetupChecklistItem.Status
            if case .manual(let step) = kind, state.manualStepsDone.contains(step) {
                status = .done
            } else if index < currentIndex {
                status = .done
            } else {
                status = index == currentIndex ? .active : .pending
            }
            return ChatSetupChecklistItem(kind: kind, status: status)
        }
    }

    public func identityPreview(name: String) -> ChatIdentityPreview? {
        provider.map { ChatIdentityPreview(name: name, policy: $0.identityPolicy) }
    }

    public func load() async {
        loadFailed = false
        do {
            providers = try await client.providers()
            if provider == nil, let pick = providers.first(where: { $0.providerId == preferredProvider }) ?? (providers.count == 1 ? providers.first : nil) {
                provider = pick
            }
        } catch ChatInstallClientError.unsupported {
            unsupported = true
            return
        } catch is CancellationError {
            return
        } catch {
            loadFailed = true
            return
        }
        await refresh()
    }

    public func choose(_ capabilities: ChatCapabilitiesWire) async {
        provider = capabilities
        snapshot = nil
        await refresh()
    }

    public func refresh() async {
        guard let scope else { return }
        do {
            adopt(try await client.status(scope))
            loadFailed = false
        } catch is CancellationError {
        } catch {
            if snapshot == nil { loadFailed = true } else { notice = .offline }
        }
        if state?.step == .ready { await refreshSpaces() }
    }

    public func receive(_ payload: ChatInstallChangedPayload) async {
        let incoming = payload.state
        guard incoming.bot == botName, incoming.providerId == provider?.providerId else { return }
        guard let current = state else { return await refresh() }
        guard incoming.revision > current.revision else { return }
        guard incoming.revision == current.revision + 1 else { return await refresh() }
        snapshot?.state = incoming
        if incoming.step == .ready { await refreshSpaces() }
    }

    public func begin() async {
        guard let scope, let state, state.step == .notStarted || state.step == .revoked else { return }
        await mutate { try await self.client.begin(scope) }
    }

    public func saveCredential(access: String, refresh: String?) async {
        guard let scope, let state, state.step == .needsCredential else { return }
        let label = credentialLabel
        await mutate {
            let id = try await self.client.storeSecret(label: label, value: access)
            if let refresh { _ = try await self.client.storeSecret(label: label + " (refresh)", value: refresh) }
            try await self.client.advance(scope, ChatInstallAdvance(event: .credentialSaved, expectedRevision: state.revision, vaultItemId: id))
        }
    }

    public func markDone(_ step: ChatProviderCapability, secret: String? = nil) async {
        guard let scope, let state, state.step == .needsManualStep, pendingTask == step else { return }
        let label = credentialLabel + " app key"
        await mutate {
            var id: String?
            if let secret { id = try await self.client.storeSecret(label: label, value: secret) }
            try await self.client.advance(scope, ChatInstallAdvance(event: .manualStepDone, expectedRevision: state.revision, manualStep: step, vaultItemId: id))
        }
    }

    public func fix() async {
        guard let scope, let state, state.step == .error else { return }
        await mutate { try await self.client.advance(scope, ChatInstallAdvance(event: .retry, expectedRevision: state.revision)) }
    }

    public func disconnect() async {
        guard let scope else { return }
        await mutate { try await self.client.revoke(scope) }
        spaces = []
        invites = [:]
    }

    public func join(_ spaceId: String) async {
        guard let scope else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await client.join(scope, spaceId: spaceId)
            if result.outcome == .needsInvite { invites[spaceId] = result.nextAction } else { invites[spaceId] = nil }
        } catch is CancellationError {
        } catch {
            notice = .notSaved
        }
        await refreshSpaces()
    }

    public func refreshSpaces() async {
        guard let scope, state?.step == .ready else { return }
        do {
            async let listed = client.spaces(scope)
            async let bound = client.bindings(scope)
            let (spaceList, bindings) = try await (listed, bound)
            let live = Set(bindings.filter(\.live).map(\.spaceId))
            spaces = spaceList.filter { $0.kind != .direct }.map { space in
                let status: ChatSpaceStatus
                if live.contains(space.id) {
                    status = .live
                } else if space.joined {
                    status = .joining
                } else {
                    status = space.kind == .private ? .needsInvite : .available
                }
                return ChatSpaceRow(space: space, status: status, invite: status == .live ? nil : invites[space.id])
            }
        } catch is CancellationError {
        } catch {
            notice = .offline
        }
    }

    public func dismissNotice() { notice = nil }

    private var scope: ChatInstallScope? {
        provider.map { ChatInstallScope(provider: $0.providerId, workspace: state?.workspace ?? "") }
    }

    private var credentialLabel: String {
        let provider = provider?.providerId.capitalized ?? ""
        return "\(provider) setup for \(botName)"
    }

    private var pendingTask: ChatProviderCapability? {
        guard let state else { return nil }
        if let id = ChatProviderCapability(rawValue: state.nextAction.actionId), Self.guidedSteps.contains(id) { return id }
        return checklist.lazy.compactMap { item -> ChatProviderCapability? in
            if case .manual(let step) = item.kind, item.status != .done { return step }
            return nil
        }.first
    }

    private func activeKind(_ state: ChatSetupStateWire) -> ChatSetupChecklistItem.Kind? {
        switch state.step {
        case .needsCredential: .workspace
        case .creatingApp: .createApp
        case .needsManualStep:
            ChatProviderCapability(rawValue: state.nextAction.actionId).map { .manual($0) }
        case .needsAllow: .allow
        case .installing: .install
        default: nil
        }
    }

    private func adopt(_ result: ChatInstallStatusResult) {
        if let current = state, result.state.revision < current.revision { return }
        snapshot = result
    }

    private func mutate(_ work: @escaping @MainActor () async throws -> Void) async {
        isWorking = true
        notice = nil
        defer { isWorking = false }
        do {
            try await work()
        } catch is CancellationError {
            return
        } catch ChatInstallClientError.staleRevision {
        } catch ChatInstallClientError.offline {
            notice = .offline
        } catch {
            notice = .notSaved
        }
        await refresh()
    }
}
