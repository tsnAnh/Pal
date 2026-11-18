import Foundation
import Observation
import PalConnect

enum OwnerSetupError: Error, Equatable {
    case check(SetupCheckFailure)
    case tokenRefused
    case pasteRefused(String)
    case unsupportedGuide
}

struct OwnerSetupStart {
    var failure: SetupStatus?
    var atClient = false
}

@MainActor
@Observable
final class OwnerSetupModel: Identifiable {
    enum Phase {
        case loading
        case ready(StepFlowModel)
        case failed(SetupStatus)
    }

    enum AddressCheck: Equatable {
        case idle
        case checking
        case reachable
        case failed(SetupStatus)
    }

    let app: ConnectApp
    let id: String
    var confirmsReplace = false
    var confirmsRemove = false
    private(set) var phase: Phase = .loading
    var addressCheck: AddressCheck = .idle
    var configured = false
    var isRemoving = false
    var removalFailure: SetupStatus?

    @ObservationIgnored let service: ConnectAppsService
    @ObservationIgnored var entry: PalCatalogEntry
    @ObservationIgnored var context: OwnerSetupContext?
    @ObservationIgnored var pasteSession: (any McpPasteSigning)?
    @ObservationIgnored private var pendingStart: OwnerSetupStart
    @ObservationIgnored private let finished: () async -> Void
    @ObservationIgnored private var isLoading = false

    init(
        app: ConnectApp, entry: PalCatalogEntry, service: ConnectAppsService, start: OwnerSetupStart = OwnerSetupStart(),
        finished: @escaping () async -> Void
    ) {
        self.app = app
        id = app.id
        self.entry = entry
        self.service = service
        pendingStart = start
        self.finished = finished
    }

    var usesClient: Bool { entry.method == .oauthClient }

    var currentStep: FlowStep? {
        if case .ready(let flow) = phase { flow.engine.current } else { nil }
    }

    func start() async {
        guard case .loading = phase, !isLoading else { return }
        await load()
    }

    func retry() async {
        phase = .loading
        await load()
    }

    func finish() async {
        discard()
        await finished()
    }

    func discard() {
        guard let session = pasteSession else { return }
        pasteSession = nil
        Task { await session.cancel() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await open()
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(status(for: error))
        }
    }

    private func open() async throws {
        let fresh = try await service.catalogEntry(slug: entry.slug) ?? entry
        guard let guide = fresh.setupGuide else { throw OwnerSetupError.unsupportedGuide }
        let uses = fresh.method == .oauthClient
        var redirect: String?
        var saved = false
        if uses {
            let setup = try await service.oauthClientSetup(slug: fresh.slug)
            redirect = setup.redirectURL
            saved = setup.configured
        }
        let platform = ConnectorPlatform.current
        let built = OwnerSetupContext(
            slug: fresh.slug, appName: app.name, guide: guide, usesClient: uses, redirectURL: redirect,
            includesAddressStep: OwnerSetupFlow.needsAddressStep(guide: guide, redirectURL: redirect), configured: saved,
            pasteRoute: uses && McpConnectRoute.decide(requires: [], platform: platform) == .pasteAddress
        )
        guard let steps = OwnerSetupFlow.steps(built) else { throw OwnerSetupError.unsupportedGuide }
        let flowID = OwnerSetupFlow.flowID(slug: built.slug)
        var resume = OwnerSetupFlow.resume(built, gatewayProgress: fresh.setupProgress)
        if pendingStart.atClient, let pasteID = Self.pasteStepID(built) {
            resume = StepFlowProgress(flowID: flowID, stepID: pasteID)
        }
        guard let engine = StepFlowEngine(flowID: flowID, steps: steps, resume: resume) else { throw ConnectAppsError.failed }
        let flow = makeFlow(engine)
        if let failure = pendingStart.failure { flow.presentFailure(failure) }
        pendingStart = OwnerSetupStart()
        entry = fresh
        context = built
        configured = saved
        phase = .ready(flow)
    }

    func makeFlow(_ engine: StepFlowEngine) -> StepFlowModel {
        let name = app.name
        let valueName = usesClient ? "client" : "token"
        let device = ConnectorPlatform.current.deviceWord
        return StepFlowModel(
            engine: engine,
            runner: { @Sendable [weak self] step, values in
                guard let self else { return }
                try await self.run(step, values)
            },
            classify: { @Sendable error in
                OwnerSetupModel.classify(error, appName: name, valueName: valueName, device: device)
            }
        )
    }

    func status(for error: any Error) -> SetupStatus {
        Self.classify(error, appName: app.name, valueName: usesClient ? "client" : "token", device: ConnectorPlatform.current.deviceWord)
    }

    nonisolated static func classify(_ error: any Error, appName: String, valueName: String, device: String) -> SetupStatus {
        switch error as? OwnerSetupError {
        case .check(let failure)?:
            SetupStatus.checkFailed(failure, subject: appName, valueName: valueName)
        case .tokenRefused?:
            SetupStatus(code: SetupStatusClass.vendorRefusedValue.rawValue, subject: appName, valueName: "token")
        case .pasteRefused(let note)?:
            SetupStatus.pasteRefused(note: note)
        case .unsupportedGuide?:
            SetupStatus(code: "unsupported", method: "connectors.catalog", subject: appName, valueName: valueName)
        case nil:
            SetupStatus(error: error, subject: appName, valueName: valueName, device: device)
        }
    }

    static func pasteStepID(_ context: OwnerSetupContext) -> String? {
        context.guide.steps.first { $0.kind == .paste }?.id
    }

    func apply(_ next: OwnerSetupContext) throws {
        guard let steps = OwnerSetupFlow.steps(next) else { throw ConnectAppsError.failed }
        context = next
        if case .ready(let flow) = phase { flow.replaceSteps(steps) }
    }

    func restart(at stepID: String?) {
        guard let context, let steps = OwnerSetupFlow.steps(context) else { return }
        let flowID = OwnerSetupFlow.flowID(slug: context.slug)
        let resume = stepID.map { StepFlowProgress(flowID: flowID, stepID: $0) }
        guard let engine = StepFlowEngine(flowID: flowID, steps: steps, resume: resume) else { return }
        phase = .ready(makeFlow(engine))
    }
}

private extension ConnectorPlatform {
    var deviceWord: String {
        switch self {
        case .mac: "Mac"
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        }
    }
}
