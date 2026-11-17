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
    let address: PublicAddressModel
    var confirmsReplace = false
    var confirmsRemove = false
    var confirmsWrite = false
    private(set) var servers: DiscordServers?
    private(set) var botName: String?
    var selectedGuilds: Set<String> = []
    private(set) var readOnly = true

    private let service: ConnectAppsService
    private let finished: () async -> Void
    private let connectAgain: () -> Void
    private let removed: () async -> Void

    init(
        app: ConnectApp, entry: PalCatalogEntry, guide: SetupGuide, service: ConnectAppsService, problem: OAuthClientProblem?,
        connectAgain: @escaping () -> Void, finished: @escaping () async -> Void, removed: @escaping () async -> Void = {}
    ) {
        self.app = app
        id = app.id
        self.entry = entry
        self.guide = guide
        self.service = service
        address = PublicAddressModel(service: service)
        self.connectAgain = connectAgain
        self.finished = finished
        self.removed = removed
        index = guide.index(of: entry.setupProgress?.stepID)
        phase = problem.map(Phase.problem) ?? .loading
    }

    var step: SetupStep { guide.steps[min(index, guide.steps.count - 1)] }

    var stepCount: Int { guide.steps.count }

    var showsBack: Bool { phase == .steps && index > 0 }

    var isLastStep: Bool { index >= guide.steps.count - 1 }

    var canAdvance: Bool { step.kind != .serverPicker || !selectedGuilds.isEmpty }

    var addressProblem: SetupProblem? { guide.addressStep?.problem }

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
            if guide.needsPublicAddress, setup.redirectURL == nil, addressProblem == nil {
                index = guide.index(of: guide.addressStep?.id)
                phase = .steps
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

    func saveAddress() async {
        guard await address.save() else { return }
        await load(editing: true, resume: false)
    }

    func replaceClient() {
        index = guide.steps.lastIndex { $0.kind == .paste } ?? index
        phase = .steps
    }

    func removeClient() async {
        phase = .working
        do {
            try await service.removeOAuthClient(slug: entry.slug)
            await removed()
            await load(editing: true)
        } catch {
            phase = .problem(problem(for: error))
        }
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
            if entry.method == .botTokenStdio {
                botName = try await service.saveDiscordToken(verification)
                await refresh(resume: true)
                phase = .steps
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

    func loadServers() async {
        guard step.kind == .serverPicker || step.kind == .access, servers == nil else { return }
        do {
            let loaded = try await service.discordServers()
            servers = loaded
            selectedGuilds = Set(loaded.allowed).intersection(loaded.guilds.map(\.id))
            readOnly = loaded.readOnly
        } catch {
            phase = .problem(problem(for: error))
        }
    }

    func toggleGuild(_ id: String) {
        if selectedGuilds.contains(id) { selectedGuilds.remove(id) } else { selectedGuilds.insert(id) }
    }

    func setReadOnly(_ on: Bool) {
        if on { readOnly = true } else { confirmsWrite = true }
    }

    func confirmWrite() {
        readOnly = false
    }

    func saveAccess() async {
        guard phase == .steps, step.kind == .access, !selectedGuilds.isEmpty else { return }
        phase = .working
        do {
            try await service.saveDiscord(guildIDs: Array(selectedGuilds), readOnly: readOnly)
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
        guard var parts = URLComponents(string: address), parts.host != nil, parts.scheme?.lowercased() == "https" else { return nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.string
    }
}
