import Foundation
import HermesConnect
import HermesDiagnostics
import Observation

@MainActor
@Observable
final class CustomConnectorModel: Identifiable {
    enum Screen {
        case form
        case result
    }

    struct BotSwitch: Identifiable, Equatable {
        let id: String
        let displayName: String
        var isOn = false
        var isBusy = false
    }

    let id = UUID()
    var name = ""
    var url = ""
    var transport: CustomConnectorTransport = .http
    var auth: CustomConnectorAuth = .none
    var token = ""
    var confirmingRemove = false

    private(set) var screen: Screen
    private(set) var machine = CustomConnectorMachine()
    private(set) var tools: [ConnectorTool] = []
    private(set) var switches: [BotSwitch]
    private(set) var switchNotice: String?
    private(set) var existing: CustomConnectorInfo?
    private(set) var removed = false
    private(set) var removeFailure: ConnectorFailure?

    private let service: ConnectAppsService
    private let currentBot: String?
    private let reload: @MainActor () async -> Void
    private let diagnostics = Diagnostics.osLog()
    private var started = false

    init(
        service: ConnectAppsService, existing: CustomConnectorInfo?, bots: [CustomConnectorBot], currentBot: String?,
        reload: @escaping @MainActor () async -> Void
    ) {
        self.service = service
        self.existing = existing
        self.currentBot = currentBot
        self.reload = reload
        switches = bots.map { BotSwitch(id: $0.name, displayName: $0.displayName) }
        screen = existing == nil ? .form : .result
        if let existing { fill(from: existing) }
    }

    var isEditing: Bool { existing != nil }
    var phase: CustomConnectorPhase { machine.phase }
    var isBusy: Bool { phase.isInFlight }
    var title: String { existing?.name ?? "Custom connector" }
    var canSave: Bool { !isBusy && !name.trimmingCharacters(in: .whitespaces).isEmpty && !url.trimmingCharacters(in: .whitespaces).isEmpty }

    var failure: ConnectorFailure? {
        if case .failed(let failure) = phase { failure } else { nil }
    }

    var progressText: String? {
        switch phase {
        case .validating: "Checking details"
        case .saving: "Saving"
        case .connecting: "Connecting"
        default: nil
        }
    }

    private func fill(from info: CustomConnectorInfo) {
        name = info.name
        url = info.url
        transport = info.transport
        auth = info.auth
        token = ""
    }

    func begin() async {
        guard !started else { return }
        started = true
        guard let existing else { return }
        await verify(existing)
        await loadSwitches()
    }

    private func verify(_ info: CustomConnectorInfo) async {
        guard machine.send(.submit) else { return }
        _ = machine.send(.validated)
        _ = machine.send(.saved)
        do {
            tools = try await service.testCustomConnector(name: info.name)
            _ = machine.send(.connected(tools))
        } catch {
            _ = machine.send(.failed(Self.failure(of: error)))
        }
    }

    func save() async {
        guard machine.send(.submit) else { return }
        var draft = CustomConnectorDraft(name: name, url: url, transport: transport, auth: auth, originalAuth: existing?.auth)
        draft.bearerToken = token.isEmpty ? nil : ConnectorSecret(token)
        do {
            _ = try draft.validated()
        } catch {
            _ = machine.send(.failed(.validation(error)))
            return
        }
        _ = machine.send(.validated)
        let progress: CustomConnectorProgress = { [weak self] _ in _ = self?.machine.send(.saved) }
        let adding = existing == nil
        do {
            let result: [ConnectorTool]
            if adding {
                result = try await service.addCustomConnector(draft, progress: progress)
            } else {
                result = try await service.updateCustomConnector(draft, progress: progress)
            }
            token = ""
            tools = result
            let saved = CustomConnectorInfo(
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                url: draft.url.trimmingCharacters(in: .whitespacesAndNewlines), transport: transport, auth: auth
            )
            existing = saved
            _ = machine.send(.connected(result))
            screen = .result
            await reload()
            if adding { await enableForCurrentBot(saved.name) }
            await loadSwitches()
        } catch {
            _ = machine.send(.failed(Self.failure(of: error)))
            if !adding { await reload() }
        }
    }

    func edit() {
        guard let existing, machine.send(.reset) else { return }
        fill(from: existing)
        screen = .form
    }

    func cancelEditing() async {
        guard let existing, machine.send(.reset) else { return }
        fill(from: existing)
        screen = .result
        await verify(existing)
    }

    func remove() async {
        guard let existing else { return }
        removeFailure = nil
        do {
            try await service.removeCustomConnector(name: existing.name)
            removed = true
            await reload()
        } catch {
            removeFailure = Self.failure(of: error)
        }
    }

    func setBot(_ id: String, on: Bool) async {
        guard let existing, let index = switches.firstIndex(where: { $0.id == id }), !switches[index].isBusy else { return }
        switchNotice = nil
        switches[index].isBusy = true
        switches[index].isOn = on
        do {
            try await service.setCustomConnector(existing.name, enabled: on, forBot: id)
        } catch {
            diagnostics.info("connect", "custom toggle failed: \(Diagnostics.describe(error))")
            if let again = switches.firstIndex(where: { $0.id == id }) { switches[again].isOn = !on }
            switchNotice = "Couldn't update that bot. Try again."
        }
        if let again = switches.firstIndex(where: { $0.id == id }) { switches[again].isBusy = false }
    }

    private func enableForCurrentBot(_ name: String) async {
        guard let currentBot else { return }
        do {
            try await service.setCustomConnector(name, enabled: true, forBot: currentBot)
        } catch {
            switchNotice = "Saved, but couldn't turn it on for your bot. Use the switch below."
        }
    }

    private func loadSwitches() async {
        guard let existing else { return }
        for index in switches.indices {
            let bot = switches[index].id
            do {
                let enabled = try await service.enabledCustomConnectors(forBot: bot)
                if let current = switches.firstIndex(where: { $0.id == bot }) { switches[current].isOn = enabled.contains(existing.name) }
            } catch {
                switchNotice = "Couldn't check which bots use this connector."
            }
        }
    }

    private static func failure(of error: any Error) -> ConnectorFailure {
        (error as? ConnectorFailure) ?? .serverError
    }
}
