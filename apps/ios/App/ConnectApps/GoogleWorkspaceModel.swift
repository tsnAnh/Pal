import Foundation
import Observation
import PalAuth
import PalConnect
import PalDesign
import PalDiagnostics
import PalProtocol

@MainActor
@Observable
final class GoogleWorkspaceModel {
    enum ClientStep: Equatable {
        case clientID
        case clientSecret
    }

    private(set) var status: GoogleWorkspaceStatus? {
        didSet { if status?.state == .signedIn { authRequired = nil } }
    }
    private(set) var authRequired: ServiceSignInReason?
    private(set) var session: GoogleSignInSession?
    private(set) var secretState: SecretEntryState = .idle
    private(set) var failure: String?
    private(set) var isWorking = false
    private(set) var isLoaded = false
    private(set) var clientStep: ClientStep = .clientID
    var selection = GoogleScopeSelection()
    var onChange: (@MainActor () async -> Void)?

    private let service: GoogleWorkspaceService
    private let diagnostics = Diagnostics.osLog()
    private var pendingClientID: SecretString?

    init(service: GoogleWorkspaceService) {
        self.service = service
    }

    var isSigningIn: Bool { session != nil }

    var cardState: GoogleWorkspaceCardState {
        .resolve(status: status, signingIn: isSigningIn, failure: failure, authRequired: authRequired)
    }

    func noteAuthRequired(_ reason: ServiceSignInReason?) {
        authRequired = reason
    }

    func reloadAfterSignIn() async {
        await load()
        await onChange?()
    }

    var needsClient: Bool { status?.state == .notConfigured }

    func readBinding(_ service: GoogleService) -> Bool { selection.read.contains(service) }

    func writeBinding(_ service: GoogleService) -> Bool { selection.write.contains(service) }

    func setRead(_ service: GoogleService, _ on: Bool) { selection.setRead(service, on) }

    func setWrite(_ service: GoogleService, _ on: Bool) { selection.setWrite(service, on) }

    func load() async {
        guard !isWorking else { return }
        await run { self.status = try await self.service.status() }
        isLoaded = true
    }

    func refresh() async {
        guard !isWorking, session == nil else { return }
        await run { self.status = try await self.service.verify() }
        await onChange?()
    }

    func startSignIn() async {
        guard session == nil, !isWorking else { return }
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            let started = try await service.beginSignIn(selection)
            guard ExternalLink.open(started.authURL) else {
                await started.cancel()
                failure = String(localized: "Couldn't open your browser.")
                return
            }
            session = started
            secretState = .idle
        } catch is CancellationError {
            return
        } catch {
            failure = reason(error)
        }
    }

    func reopenSignIn() {
        if let url = session?.authURL { ExternalLink.open(url) }
    }

    func submitPasted(_ value: String) async {
        guard let session, secretState.acceptsInput else { return }
        secretState = .submitting
        switch await session.submit(value) {
        case .signedIn(let signedIn):
            status = signedIn
            self.session = nil
            secretState = .idle
        case .tryAgain(let note):
            secretState = .failure(note)
            return
        case .denied(let reason), .failed(let reason):
            self.session = nil
            secretState = .idle
            failure = reason
        }
        await onChange?()
    }

    func cancelSignIn() async {
        guard let session else { return }
        self.session = nil
        secretState = .idle
        await session.cancel()
    }

    func submitClientField(_ value: String) async {
        guard secretState.acceptsInput else { return }
        switch clientStep {
        case .clientID:
            pendingClientID = SecretString(value)
            clientStep = .clientSecret
        case .clientSecret:
            guard let clientID = pendingClientID else {
                clientStep = .clientID
                return
            }
            await saveClient(clientID: clientID, clientSecret: SecretString(value))
        }
    }

    func restartClientEntry() {
        pendingClientID = nil
        clientStep = .clientID
        secretState = .idle
    }

    func signOut(removeSetup: Bool) async {
        guard !isWorking else { return }
        await cancelSignIn()
        await run { self.status = try await self.service.signOut(removeSetup: removeSetup) }
        await onChange?()
    }

    private func saveClient(clientID: SecretString, clientSecret: SecretString) async {
        secretState = .submitting
        do {
            status = try await service.setClient(clientID: clientID, clientSecret: clientSecret)
            failure = nil
            restartClientEntry()
            await onChange?()
        } catch {
            pendingClientID = nil
            clientStep = .clientID
            secretState = .failure(reason(error))
        }
    }

    private func run(_ work: () async throws -> Void) async {
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            try await work()
        } catch is CancellationError {
            return
        } catch {
            failure = reason(error)
        }
    }

    private func reason(_ error: any Error) -> String {
        if let known = error as? GoogleWorkspaceError { return known.reason }
        diagnostics.info("google", "unexpected failure: \(Diagnostics.describe(error))")
        return GoogleWorkspaceError.failed.reason
    }
}
