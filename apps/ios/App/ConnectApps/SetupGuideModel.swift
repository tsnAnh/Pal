import Foundation
import Observation
import PalConnect

@MainActor
@Observable
final class SetupGuideModel: Identifiable {
    enum Phase: Equatable {
        case loading
        case steps
        case working
        case problem(SetupStatus)
    }

    let app: ConnectApp
    let id: String
    private(set) var entry: PalCatalogEntry
    private(set) var guide: SetupGuide
    private(set) var phase: Phase = .loading
    private(set) var index: Int
    var confirmsWrite = false
    private(set) var servers: DiscordServers?
    private(set) var botName: String?
    var selectedGuilds: Set<String> = []
    private(set) var readOnly = true

    private let service: ConnectAppsService
    private let finished: () async -> Void

    init(app: ConnectApp, entry: PalCatalogEntry, guide: SetupGuide, service: ConnectAppsService, finished: @escaping () async -> Void) {
        self.app = app
        id = app.id
        self.entry = entry
        self.guide = guide
        self.service = service
        self.finished = finished
        index = guide.index(of: entry.setupProgress?.stepID)
    }

    var step: SetupStep { guide.steps[min(index, guide.steps.count - 1)] }

    var stepCount: Int { guide.steps.count }

    var showsBack: Bool { phase == .steps && index > 0 }

    var isLastStep: Bool { index >= guide.steps.count - 1 }

    var canAdvance: Bool { step.kind != .serverPicker || !selectedGuilds.isEmpty }

    func start() async {
        if phase == .loading { await load() }
    }

    func load(resume: Bool = true) async {
        phase = .loading
        await refresh(resume: resume)
        phase = .steps
    }

    func back() {
        if showsBack { index -= 1 }
    }

    func advance() async {
        if isLastStep { await finished() } else { index += 1 }
    }

    func submit(_ values: [String: String]) async {
        guard phase == .steps, step.kind == .paste else { return }
        let current = step
        phase = .working
        do {
            let verification = try await service.verifySetup(entry, step: current, values: values)
            guard verification.result.ok else {
                let failure = verification.result.failure(appName: app.name)
                phase = .problem(SetupStatus.checkFailed(failure, subject: app.name, valueName: "token"))
                return
            }
            botName = try await service.saveDiscordToken(verification)
            await refresh(resume: true)
            phase = .steps
        } catch {
            phase = .problem(SetupStatus(error: error, subject: app.name, valueName: "token"))
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
            phase = .problem(SetupStatus(error: error, subject: app.name, valueName: "token"))
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
            phase = .problem(SetupStatus(error: error, subject: app.name, valueName: "token"))
        }
    }

    func retry() async {
        await load(resume: false)
    }

    private func refresh(resume: Bool) async {
        guard let fresh = try? await service.catalogEntry(slug: entry.slug), let freshGuide = fresh.setupGuide else { return }
        entry = fresh
        guide = freshGuide
        if resume { index = freshGuide.index(of: fresh.setupProgress?.stepID) }
        index = min(index, freshGuide.steps.count - 1)
    }
}
