import Foundation
import Observation
import PalConnect

struct OAuthClientProblem: Equatable {
    enum Retry: Equatable {
        case setup
        case connect
    }

    let code: String
    let reason: String
    let retry: Retry

    init(code: String, reason: String, retry: Retry) {
        self.code = code
        self.reason = reason
        self.retry = retry
    }

    init(_ failure: OAuthClientFailure, retry: Retry) {
        self.init(code: failure.rawValue, reason: failure.reason, retry: retry)
    }

    init(_ error: any Error, retry: Retry) {
        switch error {
        case ConnectAppsError.oauthClient(let failure): self.init(failure, retry: retry)
        case ConnectAppsError.signInFailed(let reason): self.init(code: "SIGN_IN_FAILED", reason: reason, retry: retry)
        default: self.init(.unreachable, retry: retry)
        }
    }

    init(connecting error: any Error) {
        var retry = Retry.connect
        if case ConnectAppsError.oauthClient(let failure) = error, [.needsSetup, .clientUnreadable, .invalidClient].contains(failure) {
            retry = .setup
        }
        self.init(error, retry: retry)
    }
}

@MainActor
@Observable
final class OAuthClientSheetModel: Identifiable {
    enum Phase: Equatable {
        case loading
        case form(OAuthClientSetup)
        case saving
        case problem(OAuthClientProblem)
    }

    let app: ConnectApp
    let entry: PalCatalogEntry
    private(set) var phase: Phase

    private let service: ConnectAppsService
    private let finished: () async -> Void
    private let connectAgain: () -> Void

    let id: String

    init(
        app: ConnectApp, entry: PalCatalogEntry, service: ConnectAppsService, problem: OAuthClientProblem?,
        connectAgain: @escaping () -> Void, finished: @escaping () async -> Void
    ) {
        self.app = app
        id = app.id
        self.entry = entry
        self.service = service
        self.connectAgain = connectAgain
        self.finished = finished
        phase = problem.map(Phase.problem) ?? .loading
    }

    func start() async {
        if phase == .loading { await load() }
    }

    func load(editing: Bool = false) async {
        phase = .loading
        do {
            let setup = try await service.oauthClientSetup(slug: entry.slug)
            if setup.configured && !editing {
                await finished()
            } else if setup.redirectURL == nil {
                phase = .problem(OAuthClientProblem(.needsPublicURL, retry: .setup))
            } else {
                phase = .form(setup)
            }
        } catch {
            phase = .problem(OAuthClientProblem(error, retry: .setup))
        }
    }

    func save(clientID: String, clientSecret: String) async {
        phase = .saving
        do {
            _ = try await service.saveOAuthClient(entry, clientID: clientID, clientSecret: clientSecret)
            await finished()
        } catch {
            phase = .problem(OAuthClientProblem(error, retry: .setup))
        }
    }

    func retry(_ problem: OAuthClientProblem) async {
        switch problem.retry {
        case .setup: await load(editing: true)
        case .connect: connectAgain()
        }
    }
}
