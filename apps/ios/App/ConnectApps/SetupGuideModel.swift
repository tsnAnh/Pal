import Foundation
import Observation
import PalConnect
import PalProtocol

@MainActor
@Observable
final class SetupGuideModel: Identifiable {
    enum Phase: Equatable {
        case loading
        case steps
        case saved
        case working
        case problem(OAuthClientProblem)
    }

    let app: ConnectApp
    let id: String
    private(set) var entry: PalCatalogEntry
    private(set) var guide: SetupGuide
    private(set) var phase: Phase
    private(set) var index: Int
    private(set) var publicAddress: String?
    var confirmsReplace = false

    private let service: ConnectAppsService
    private let finished: () async -> Void
    private let connectAgain: () -> Void

    init(
        app: ConnectApp, entry: PalCatalogEntry, guide: SetupGuide, service: ConnectAppsService, problem: OAuthClientProblem?,
        connectAgain: @escaping () -> Void, finished: @escaping () async -> Void
    ) {
        self.app = app
        id = app.id
        self.entry = entry
        self.guide = guide
        self.service = service
        self.connectAgain = connectAgain
        self.finished = finished
        index = guide.index(of: entry.setupProgress?.stepID)
        phase = problem.map(Phase.problem) ?? .loading
    }

    var step: SetupStep { guide.steps[min(index, guide.steps.count - 1)] }

    var stepCount: Int { guide.steps.count }

    var showsBack: Bool { phase == .steps && index > 0 }

    var isLastStep: Bool { index >= guide.steps.count - 1 }

    func start() async {
        if phase == .loading { await load() }
    }

    func load(editing: Bool = false, resume: Bool = true) async {
        phase = .loading
        await refresh(resume: resume)
        guard entry.method == .oauthClient else {
            phase = .steps
            return
        }
        do {
            let setup = try await service.oauthClientSetup(slug: entry.slug)
            publicAddress = setup.redirectURL.flatMap(Self.origin)
            if guide.needsPublicAddress, setup.redirectURL == nil {
                phase = .problem(OAuthClientProblem(.needsPublicURL, retry: .setup))
            } else {
                phase = setup.configured && !editing ? .saved : .steps
            }
        } catch {
            phase = .problem(problem(for: error))
        }
    }

    func back() {
        if showsBack { index -= 1 }
    }

    func advance() async {
        if isLastStep { await finished() } else { index += 1 }
    }

    func replaceClient() {
        index = guide.steps.lastIndex { $0.kind == .paste } ?? index
        phase = .steps
    }

    func connectSaved() {
        connectAgain()
    }

    func submit(_ values: [String: String]) async {
        guard phase == .steps, step.kind == .paste else { return }
        let current = step
        phase = .working
        do {
            let verification = try await service.verifySetup(entry, step: current, values: values)
            guard verification.result.ok else {
                let failure = verification.result.failure(appName: app.name)
                phase = .problem(OAuthClientProblem(code: failure.code, reason: failure.reason, retry: .setup))
                return
            }
            if let failure = try await store(verification, token: values["token"]) {
                phase = .problem(OAuthClientProblem(code: "INVALID_TOKEN", reason: failure, retry: .setup))
                return
            }
            await finished()
        } catch {
            phase = .problem(problem(for: error))
        }
    }

    func retry(_ problem: OAuthClientProblem) async {
        switch problem.retry {
        case .setup: await load(editing: true, resume: false)
        case .connect: connectAgain()
        }
    }

    private func store(_ verification: SetupVerification, token: String?) async throws -> String? {
        if entry.method == .oauthClient {
            try await service.saveVerifiedClient(entry, verification)
            return nil
        }
        await service.discardVerified(verification)
        try await service.connect(app, credentials: ["token": token ?? ""])
        guard let failure = await service.tokenFailure(app) else { return nil }
        return failure == .authRefused ? String(localized: "\(app.name) didn't accept that token. Check it and try again.") : failure.message
    }

    private func refresh(resume: Bool) async {
        guard let fresh = try? await service.catalogEntry(slug: entry.slug), let freshGuide = fresh.setupGuide else { return }
        entry = fresh
        guide = freshGuide
        if resume { index = freshGuide.index(of: fresh.setupProgress?.stepID) }
        index = min(index, freshGuide.steps.count - 1)
    }

    private func problem(for error: any Error) -> OAuthClientProblem {
        guard let known = error as? ConnectAppsError, let fault = known.fault else { return OAuthClientProblem(error, retry: .setup) }
        if known.oauthClientFailure == nil || known.oauthClientFailure == .connectFailed {
            return OAuthClientProblem(
                code: fault.reason.uppercased(), reason: String(localized: "Pal couldn't finish that. Try again."), retry: .setup, fault: fault
            )
        }
        return OAuthClientProblem(error, retry: .setup)
    }

    private static func origin(of address: String) -> String? {
        guard var parts = URLComponents(string: address), parts.host != nil else { return nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.string
    }
}
