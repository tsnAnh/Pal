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
    var type: CustomConnectorType = .remoteHTTPS
    var url = ""
    var headers = ConnectorHeader.withTrailingBlank([])
    var clientID = ""
    var confirmingRemove = false

    private(set) var screen: Screen
    private(set) var machine = CustomConnectorMachine()
    private(set) var tools: [ConnectorTool] = []
    private(set) var switches: [BotSwitch]
    private(set) var switchNotice: String?
    private(set) var existing: CustomConnectorInfo?
    private(set) var removeFailure: ConnectorFailure?

    private let service: ConnectAppsService
    private let currentBot: String?
    private let reload: @MainActor () async -> Void
    private let leave: @MainActor () -> Void
    private let diagnostics = Diagnostics.osLog()
    private var started = false
    private var discarded = false
    private var pending: Task<[ConnectorTool], any Error>?
    private var pendingAddName: String?

    init(
        service: ConnectAppsService, existing: CustomConnectorInfo?, bots: [CustomConnectorBot], currentBot: String?,
        reload: @escaping @MainActor () async -> Void, leave: @escaping @MainActor () -> Void
    ) {
        self.service = service
        self.existing = existing
        self.currentBot = currentBot
        self.reload = reload
        self.leave = leave
        switches = bots.map { BotSwitch(id: $0.name, displayName: $0.displayName) }
        screen = existing == nil ? .form : .result
        if let existing { fill(from: existing) }
    }

    var isEditing: Bool { existing != nil }
    var phase: CustomConnectorPhase { machine.phase }
    var isBusy: Bool { phase.isInFlight }

    var heading: String {
        switch screen {
        case .form: isEditing ? "Edit custom connector" : "Add a custom connector"
        case .result: existing?.name ?? "Custom connector"
        }
    }

    var submitTitle: String { isEditing ? "Save" : "Add plugin" }

    var draft: CustomConnectorDraft {
        CustomConnectorDraft(
            name: name, type: type, url: url, headers: headers, clientID: clientID, originalHeaderKeys: existing?.headerKeys ?? []
        )
    }

    var canSubmit: Bool { !isBusy && draft.canSubmit }

    var addressPreview: String? {
        let typed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = draft.normalizedURL, normalized != typed else { return nil }
        return normalized
    }

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

    func index(ofHeader id: UUID) -> Int {
        headers.firstIndex { $0.id == id } ?? 0
    }

    func ensureTrailingHeaderRow() {
        let padded = ConnectorHeader.withTrailingBlank(headers)
        if padded.count != headers.count { headers = padded }
    }

    func removeHeader(_ id: UUID) {
        headers = ConnectorHeader.withTrailingBlank(headers.filter { $0.id != id })
    }

    private func fill(from info: CustomConnectorInfo) {
        name = info.name
        type = info.type
        url = info.url
        headers = ConnectorHeader.stored(keys: info.headerKeys)
        clientID = info.clientID ?? ""
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

    func submit() async {
        guard !discarded, machine.send(.submit) else { return }
        let draft = draft
        let connector: ValidatedConnector
        do {
            connector = try draft.validated()
        } catch {
            _ = machine.send(.failed(.validation(error)))
            return
        }
        _ = machine.send(.validated)
        let adding = existing == nil
        let service = service
        let progress: CustomConnectorProgress = { [weak self] _ in
            guard let self else { return }
            _ = self.machine.send(.saved)
            if adding { self.pendingAddName = connector.name }
        }
        let task = Task { () throws -> [ConnectorTool] in
            if adding {
                return try await service.addCustomConnector(draft, progress: progress)
            }
            return try await service.updateCustomConnector(draft, progress: progress)
        }
        pending = task
        do {
            let result = try await task.value
            pending = nil
            pendingAddName = nil
            guard !discarded else { return }
            complete(result, connector: connector)
            await reload()
            if adding { await enableForCurrentBot(connector.name) }
            await loadSwitches()
        } catch {
            pending = nil
            guard !discarded else { return }
            _ = machine.send(.failed(Self.failure(of: error)))
            if !adding { await reload() }
        }
    }

    private func complete(_ result: [ConnectorTool], connector: ValidatedConnector) {
        tools = result
        let keys = connector.headers.map(\.key)
        let info = CustomConnectorInfo(name: connector.name, url: connector.url, type: connector.type, headerKeys: keys, clientID: connector.clientID)
        existing = info
        fill(from: info)
        _ = machine.send(.connected(result))
        screen = .result
    }

    func edit() {
        guard let existing, machine.send(.reset) else { return }
        fill(from: existing)
        screen = .form
    }

    func discard() async {
        discarded = true
        guard let task = pending else { return }
        task.cancel()
        let finished = (try? await task.value) != nil
        pending = nil
        if finished, let added = pendingAddName {
            try? await service.removeCustomConnector(name: added)
        }
        pendingAddName = nil
    }

    func remove() async {
        guard let existing else { return }
        removeFailure = nil
        do {
            try await service.removeCustomConnector(name: existing.name)
            await reload()
            leave()
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
