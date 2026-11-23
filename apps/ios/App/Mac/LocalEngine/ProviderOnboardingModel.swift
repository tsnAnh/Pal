#if os(macOS)
import Foundation
import Observation
import PalBotProfile
import PalProtocol

@MainActor
@Observable
final class ProviderOnboardingModel {
    enum Screen: Hashable {
        case choice
        case morePlans
        case moreKeys
        case signIn(String)
        case claude(String)
        case key(String)
        case local
        case test(String)
    }

    enum Origin: Equatable {
        case written
        case staged
        case external
    }

    enum CatalogState: Equatable {
        case idle
        case loading
        case loaded([String])
        case unavailable
    }

    enum HostCheckState: Equatable {
        case idle
        case checking
        case checked(ProviderHostCheck)
        case failed(String)
        case installing
        case installFailed(String)
    }

    let providers: ModelProvidersModel
    let flow: ProviderTestFlow
    var searchText = ""
    var showsAllModels = false
    private(set) var stack: [Screen] = [.choice]
    private(set) var origin = Origin.written
    var connectedHere: String?
    private(set) var isFinishing = false
    var selectedModel: String?
    var manualModel = ""
    var catalog = CatalogState.idle
    var hostCheck = HostCheckState.idle

    @ObservationIgnored let client: ModelProvidersClient
    @ObservationIgnored let models: BotModelClient
    @ObservationIgnored var catalogTask: Task<Void, Never>?
    @ObservationIgnored var clipboardMark: Int?
    @ObservationIgnored private let onFinish: @MainActor (Bool) -> Void

    init(
        providers: ModelProvidersModel, flow: ProviderTestFlow, client: ModelProvidersClient, models: BotModelClient,
        finish: @escaping @MainActor (Bool) -> Void
    ) {
        self.providers = providers
        self.flow = flow
        self.client = client
        self.models = models
        onFinish = finish
    }

    var screen: Screen { stack.last ?? .choice }

    var canGoBack: Bool { stack.count > 1 }

    var isBusy: Bool {
        if isFinishing || flow.isSaving || hostCheck == .installing { return true }
        if flow.state == .testing || flow.state == .slow { return true }
        if case .signIn = screen { return true }
        return false
    }

    var title: String {
        switch screen {
        case .choice: String(localized: "Choose your AI")
        case .morePlans: String(localized: "More plans")
        case .moreKeys: String(localized: "More providers")
        case .signIn(let id): String(localized: "Sign in to \(displayName(id))")
        case .claude: String(localized: "Claude on this Mac")
        case .key(let id): String(localized: "Add your \(displayName(id)) key")
        case .local: String(localized: "Local or custom address")
        case .test(let id): String(localized: "Test \(displayName(id))")
        }
    }

    func displayName(_ id: String) -> String {
        providers.provider(id: id).map { FirstRunProviders.choice(for: $0).name } ?? id
    }

    static func screen(for provider: ModelProvider) -> Screen? {
        switch provider.kind {
        case .deviceCode, .oauthPaste: Screen.signIn(provider.id)
        case .cliPlan: Screen.claude(provider.id)
        case .apiKey: provider.id == FirstRunProviders.localProviderID ? Screen.local : Screen.key(provider.id)
        case .unsupported, .unknown: nil
        }
    }

    static func actionTitle(for provider: ModelProvider) -> String {
        switch provider.kind {
        case .deviceCode, .oauthPaste: String(localized: "Sign in")
        case .cliPlan: String(localized: "Set up")
        case .apiKey: provider.id == FirstRunProviders.localProviderID ? String(localized: "Set up") : String(localized: "Add key")
        case .unsupported, .unknown: String(localized: "Set up")
        }
    }

    var searchResults: [ModelProvider] {
        FirstRunProviders.filter(Self.offered(providers.layout), query: searchText)
    }

    var continueTarget: ModelProvider? {
        if let id = connectedHere, let provider = providers.provider(id: id), provider.state == .set { return provider }
        if let offered = Self.offered(providers.layout).first(where: { $0.state == .set }) { return offered }
        return providers.providers.first { $0.state == .set && $0.canSignIn }
    }

    var inlineSignInService: String? {
        guard case .signIn(let id) = screen else { return nil }
        return ModelProvidersClient.serviceKey + id
    }

    private static func offered(_ layout: FirstRunLayout) -> [ModelProvider] {
        var all = layout.subscriptions.map(\.provider)
        all += layout.keys.map(\.provider)
        if let local = layout.local { all.append(local) }
        all += layout.morePlans
        all += layout.moreKeys
        return all
    }

    func push(_ next: Screen) {
        stack.append(next)
        searchText = ""
    }

    func replaceTop(with next: Screen) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1] = next
        searchText = ""
    }

    func back() async {
        guard canGoBack else { return }
        let leaving = screen
        stack.removeLast()
        searchText = ""
        await leave(leaving)
    }

    func escape() {
        Task { if canGoBack { await back() } else { await skip() } }
    }

    func resetToChoice() {
        stack = [.choice]
        searchText = ""
    }

    func choose(_ provider: ModelProvider) async {
        guard provider.canSignIn, !isFinishing else { return }
        if provider.state == .set {
            startTest(provider)
            return
        }
        guard let next = Self.screen(for: provider) else { return }
        push(next)
        if case .signIn = next { await providers.signIn(provider) }
    }

    func retrySignIn(_ provider: ModelProvider) async {
        await providers.signIn(provider)
    }

    func signInSettled() async {
        guard case .signIn(let id) = screen, case .succeeded = providers.status(of: id) else { return }
        await providers.refresh()
        if flow.state != .signingIn, flow.holdsUnprovenWrittenCredential, flow.provider?.id != id { await flow.skip() }
        guard case .signIn(let current) = screen, current == id, let provider = providers.provider(id: id) else { return }
        connectedHere = id
        if flow.state == .signingIn {
            flow.credentialWritten()
            stack.removeLast()
        } else {
            begin(provider, credential: .written, owns: true, replacingTop: true)
        }
    }

    func continueToTest() {
        guard let provider = continueTarget else { return }
        startTest(provider)
    }

    func continueWithKey(_ providerID: String, key: SecretString) {
        guard let provider = providers.provider(id: providerID) else { return }
        begin(provider, credential: .staged(apiKey: key, baseURL: nil), owns: false)
    }

    func continueWithLocal(address: String, key: SecretString?) {
        guard let provider = providers.provider(id: FirstRunProviders.localProviderID) else { return }
        begin(provider, credential: .staged(apiKey: key, baseURL: address), owns: false)
    }

    func skip() async {
        guard !isFinishing else { return }
        isFinishing = true
        let removed = await flow.skip()
        await finish(removalSucceeded: removed)
    }

    func finish(removalSucceeded: Bool = true) async {
        isFinishing = true
        let refreshed = await providers.refresh()
        onFinish(refreshed && removalSucceeded && providers.hasConnectedProvider)
    }

    func startTest(_ provider: ModelProvider) {
        begin(provider, credential: provider.kind == .cliPlan ? .external : .written, owns: false)
    }

    func begin(_ provider: ModelProvider, credential: ProviderCredential, owns: Bool, replacingTop: Bool = false) {
        let continuesOwnedSignIn = owns && flow.provider?.id == provider.id
        guard !flow.holdsUnprovenWrittenCredential || continuesOwnedSignIn else { return }
        origin = Self.origin(of: credential)
        flow.start(provider: provider, credential: credential, ownsCredential: owns)
        selectedModel = nil
        manualModel = ""
        showsAllModels = false
        if replacingTop {
            replaceTop(with: .test(provider.id))
        } else {
            push(.test(provider.id))
        }
        loadCatalog(for: provider.id)
    }

    private static func origin(of credential: ProviderCredential) -> Origin {
        switch credential {
        case .written: .written
        case .staged: .staged
        case .external: .external
        }
    }

    private func leave(_ screen: Screen) async {
        switch screen {
        case .test:
            catalogTask?.cancel()
            if flow.state == .testing || flow.state == .slow { flow.cancelTest() }
            if origin != .written {
                flow.discard()
            } else if flow.holdsUnprovenWrittenCredential {
                await flow.skip()
            }
        case .signIn:
            flow.signInCancelled()
        case .claude:
            hostCheck = .idle
        case .choice, .morePlans, .moreKeys, .key, .local:
            break
        }
    }
}
#endif
