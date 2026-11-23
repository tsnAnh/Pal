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

    public private(set) var state: ProviderTestState = .idle
    public private(set) var provider: ModelProvider?
    public private(set) var model: String?
    public private(set) var ownsCredential = false
    public private(set) var isSaving = false

    private var credential: ProviderCredential?
    @ObservationIgnored private var hasPassed = false
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
        slowAfter: Duration = .seconds(10),
        giveUpAfter: Duration = .seconds(35)
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
        if case .passed = state { !isSaving } else { false }
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
            model = chosen
            state = .modelChanged
        case .failed, .offline:
            model = chosen
            state = .awaitingTest
        case .awaitingTest, .modelChanged:
            model = chosen
        case .idle, .signingIn, .testing, .slow:
            return
        }
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
        isSaving = true
        defer { if epoch == lifetime { isSaving = false } }
        if case .staged(let apiKey, let baseURL)? = credential, apiKey != nil || baseURL != nil {
            if let reason = await backend.saveStaged(provider: provider.id, apiKey: apiKey, baseURL: baseURL) {
                return saveFailed(reason, epoch)
            }
        }
        if let reason = await backend.pin(ModelChoice(provider: provider.id, model: model)) {
            return saveFailed(reason, epoch)
        }
        guard epoch == lifetime else { return false }
        credential = nil
        ownsCredential = false
        state = .idle
        return true
    }

    public func skip() async {
        let abandoned = hasPassed ? nil : writtenProviderID
        reset()
        if let abandoned { _ = await backend.remove(provider: abandoned) }
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

    private var writtenProviderID: String? {
        ownsCredential && credential == .written ? provider?.id : nil
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
        case .deadline: state = .failed(reason: Self.tookTooLong, kind: .timeout)
        case .finished(let result): conclude(result)
        }
    }

    private func conclude(_ result: ProviderTestResult) {
        if result.ok {
            hasPassed = true
            let tested = model ?? result.model
            state = .passed(ProviderTestPass(model: tested, latencyMilliseconds: result.latencyMilliseconds, replyPreview: result.replyPreview))
        } else if let error = result.error {
            state = error.kind == .network ? .offline : .failed(reason: error.reason, kind: error.kind)
        } else {
            state = .failed(reason: Self.didNotPass, kind: .other)
        }
    }

    private func saveFailed(_ reason: String, _ epoch: Int) -> Bool {
        if epoch == lifetime { state = .failed(reason: reason, kind: .other) }
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
        isSaving = false
        state = .idle
    }
}
