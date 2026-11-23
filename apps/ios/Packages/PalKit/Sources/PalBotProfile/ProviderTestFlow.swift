import Foundation
import Observation
import PalProtocol

public enum ProviderCredential: Sendable, Equatable {
    case written
    case staged(apiKey: SecretString?, baseURL: String?)
    case external
}

public protocol ProviderTestBackend: Sendable {
    func runTest(_ request: ProviderTestRequest) async -> ProviderTestResult
    func saveStaged(provider: String, apiKey: SecretString?, baseURL: String?) async -> String?
    func pin(_ choice: ModelChoice) async -> String?
    func remove(provider: String) async -> Bool
}

public struct ProviderTestPass: Sendable, Equatable {
    public let model: String
    public let latencyMilliseconds: Int
    public let replyPreview: String?

    public init(model: String, latencyMilliseconds: Int, replyPreview: String? = nil) {
        self.model = model
        self.latencyMilliseconds = latencyMilliseconds
        self.replyPreview = replyPreview
    }
}

public enum ProviderTestState: Sendable, Equatable {
    case idle
    case signingIn
    case awaitingTest
    case testing
    case slow
    case passed(ProviderTestPass)
    case failed(reason: String, kind: ProviderTestFailureKind)
    case offline
    case modelChanged
}

@MainActor
@Observable
public final class ProviderTestFlow {
    public nonisolated static let tookTooLong = "The test took too long. Try again."
    public nonisolated static let didNotPass = "The test didn't pass. Try again."
    public nonisolated static let saveFailed = "Couldn't save. Nothing was changed. Try again."
    public nonisolated static let saveFailedPartway = "Couldn't finish saving. Try again."
    public nonisolated static let defaultSlowAfterSeconds = 10
    public nonisolated static let defaultSlowAfter = Duration.seconds(defaultSlowAfterSeconds)
    public nonisolated static let defaultGiveUpAfter = Duration.seconds(ProviderTestRequest.defaultTimeoutSeconds + 10)

    public private(set) var state: ProviderTestState = .idle
    public private(set) var provider: ModelProvider?
    public private(set) var model: String?
    public private(set) var ownsCredential = false
    public private(set) var isSaving = false

    private var credential: ProviderCredential?
    @ObservationIgnored private var hasPassed = false
    @ObservationIgnored private var wasConnectedAtStart = false
    @ObservationIgnored private var isRemoving = false
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var lifetime = 0
    @ObservationIgnored private var inFlight: ProviderTestRun?
    @ObservationIgnored private var stateBeforeSignIn: ProviderTestState = .idle
    @ObservationIgnored private let backend: any ProviderTestBackend
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let slowAfter: Duration
    @ObservationIgnored private let giveUpAfter: Duration

    public init(
        backend: any ProviderTestBackend,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        slowAfter: Duration = ProviderTestFlow.defaultSlowAfter,
        giveUpAfter: Duration = ProviderTestFlow.defaultGiveUpAfter
    ) {
        self.backend = backend
        self.sleep = sleep
        self.slowAfter = slowAfter
        self.giveUpAfter = giveUpAfter
    }

    public var hasStagedSecret: Bool {
        if case .staged(let apiKey, _)? = credential { apiKey != nil } else { false }
    }

    public var canTest: Bool {
        guard model != nil, !isSaving else { return false }
        switch state {
        case .awaitingTest, .modelChanged, .failed, .offline, .passed: return true
        case .idle, .signingIn, .testing, .slow: return false
        }
    }

    public var canSaveAndContinue: Bool {
        if case .passed = state { model != nil && !isSaving } else { false }
    }

    public var holdsUnprovenWrittenCredential: Bool {
        ownsCredential && credential == .written && !hasPassed
    }

    public var canChangeModelAfterFailure: Bool {
        if case .failed(_, .model) = state { true } else { false }
    }

    public var canSignInAgain: Bool {
        if case .failed(_, .auth) = state { credential == .written } else { false }
    }

    public var canRemove: Bool {
        guard ownsCredential, credential == .written, !isSaving else { return false }
        switch state {
        case .failed, .offline, .awaitingTest: return true
        case .idle, .signingIn, .testing, .slow, .passed, .modelChanged: return false
        }
    }

    public func start(provider: ModelProvider, credential: ProviderCredential, ownsCredential: Bool) {
        reset()
        self.provider = provider
        self.credential = credential
        self.ownsCredential = ownsCredential
        wasConnectedAtStart = provider.state == .set
        state = .awaitingTest
    }

    public func beginSigningIn(provider: ModelProvider) {
        guard state != .signingIn, !isSaving else { return }
        if self.provider?.id != provider.id { reset() }
        invalidateTest()
        let resting: ProviderTestState = isTesting ? .awaitingTest : state
        stateBeforeSignIn = self.provider == nil ? .idle : resting
        self.provider = provider
        state = .signingIn
    }

    public func signInCancelled() {
        guard state == .signingIn else { return }
        state = stateBeforeSignIn
    }

    public func credentialWritten() {
        guard provider != nil, !isSaving else { return }
        invalidateTest()
        credential = .written
        ownsCredential = true
        hasPassed = false
        state = .awaitingTest
    }

    public func select(model chosen: String) {
        guard provider != nil, !chosen.isEmpty, chosen != model, !isSaving else { return }
        switch state {
        case .passed:
            state = .modelChanged
        case .failed, .offline:
            state = .awaitingTest
        case .awaitingTest, .modelChanged:
            break
        case .idle, .signingIn, .testing, .slow:
            return
        }
        model = chosen
        hasPassed = false
    }

    public func clearModel() {
        guard provider != nil, model != nil, !isSaving else { return }
        switch state {
        case .passed: state = .modelChanged
        case .awaitingTest, .modelChanged, .failed, .offline: break
        case .idle, .signingIn, .testing, .slow: return
        }
        model = nil
        hasPassed = false
    }

    public func test() async {
        guard canTest, let provider, let model else { return }
        attempt &+= 1
        let mine = attempt
        state = .testing
        let run = ProviderTestRun(
            backend: backend, request: request(provider: provider.id, model: model), sleep: self.sleep,
            slowAfter: slowAfter, giveUpAfter: giveUpAfter)
        inFlight = run
        for await step in run.steps {
            guard attempt == mine else { break }
            apply(step)
            if !isTesting { break }
        }
        run.stop()
        guard attempt == mine else { return }
        inFlight = nil
        if isTesting { state = .awaitingTest }
    }

    public func cancelTest() {
        guard inFlight != nil else { return }
        invalidateTest()
        state = .awaitingTest
    }

    public func saveAndContinue() async -> Bool {
        guard canSaveAndContinue, let provider, let model else { return false }
        let epoch = lifetime
        let staged = stagedWrite
        let rollback = staged != nil && !wasConnectedAtStart ? provider.id : nil
        isSaving = true
        defer { if epoch == lifetime { isSaving = false } }
        if let staged, await backend.saveStaged(provider: provider.id, apiKey: staged.apiKey, baseURL: staged.baseURL) != nil {
            return await saveFailed(rollingBack: rollback, epoch)
        }
        if await backend.pin(ModelChoice(provider: provider.id, model: model)) != nil {
            return await saveFailed(rollingBack: rollback, epoch)
        }
        guard epoch == lifetime else { return false }
        credential = nil
        ownsCredential = false
        state = .idle
        return true
    }

    @discardableResult
    public func skip() async -> Bool {
        let abandoned = holdsUnprovenWrittenCredential ? provider?.id : nil
        reset()
        guard let abandoned else { return true }
        return await backend.remove(provider: abandoned)
    }

    public func remove() async -> Bool {
        guard canRemove, !isRemoving, let id = provider?.id else { return false }
        isRemoving = true
        defer { isRemoving = false }
        let epoch = lifetime
        let removed = await backend.remove(provider: id)
        if removed, epoch == lifetime { reset() }
        return removed
    }

    public func discard() {
        reset()
    }

    private var stagedWrite: (apiKey: SecretString?, baseURL: String?)? {
        guard case .staged(let apiKey, let baseURL)? = credential, apiKey != nil || baseURL != nil else { return nil }
        return (apiKey, baseURL)
    }

    private func request(provider: String, model: String) -> ProviderTestRequest {
        guard case .staged(let apiKey, let baseURL)? = credential else {
            return ProviderTestRequest(provider: provider, model: model)
        }
        return ProviderTestRequest(provider: provider, model: model, baseURL: baseURL, apiKey: apiKey)
    }

    private var isTesting: Bool { state == .testing || state == .slow }

    private func apply(_ step: ProviderTestRun.Step) {
        switch step {
        case .slow: if state == .testing { state = .slow }
        case .deadline:
            hasPassed = false
            state = .failed(reason: Self.tookTooLong, kind: .timeout)
        case .finished(let result): conclude(result)
        }
    }

    private func conclude(_ result: ProviderTestResult) {
        if result.ok {
            hasPassed = true
            let tested = model ?? result.model
            state = .passed(ProviderTestPass(model: tested, latencyMilliseconds: result.latencyMilliseconds, replyPreview: result.replyPreview))
        } else if let error = result.error {
            if error.kind == .network {
                state = .offline
            } else {
                hasPassed = false
                state = .failed(reason: error.reason, kind: error.kind)
            }
        } else {
            hasPassed = false
            state = .failed(reason: Self.didNotPass, kind: .other)
        }
    }

    private func saveFailed(rollingBack providerID: String?, _ epoch: Int) async -> Bool {
        var undone = true
        if let providerID { undone = await backend.remove(provider: providerID) }
        if epoch == lifetime { state = .failed(reason: undone ? Self.saveFailed : Self.saveFailedPartway, kind: .other) }
        return false
    }

    private func invalidateTest() {
        attempt &+= 1
        inFlight?.stop()
        inFlight = nil
    }

    private func reset() {
        invalidateTest()
        lifetime &+= 1
        provider = nil
        model = nil
        credential = nil
        ownsCredential = false
        hasPassed = false
        wasConnectedAtStart = false
        isSaving = false
        state = .idle
    }
}
