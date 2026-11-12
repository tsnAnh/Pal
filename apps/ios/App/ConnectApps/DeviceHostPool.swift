import Foundation
import PalClient
import PalDevice
import PalDiagnostics
import PalProtocol
import Observation

@MainActor
@Observable
final class DeviceConsentPresenter: ConsentPrompting {
    struct Pending: Identifiable {
        let id = UUID()
        let ask: ConsentAsk
        let botName: String
    }

    private(set) var pending: Pending?
    private var queue: [(Pending, CheckedContinuation<Bool, Never>)] = []
    private var current: CheckedContinuation<Bool, Never>?
    private let botName: @MainActor (String) -> String

    init(botName: @escaping @MainActor (String) -> String) {
        self.botName = botName
    }

    func askConsent(_ ask: ConsentAsk) async -> Bool {
        let entry = Pending(ask: ask, botName: botName(ask.profile))
        return await withCheckedContinuation { continuation in
            if pending == nil {
                pending = entry
                current = continuation
            } else {
                queue.append((entry, continuation))
            }
        }
    }

    func answer(_ allowed: Bool) {
        current?.resume(returning: allowed)
        current = nil
        pending = nil
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        pending = next.0
        current = next.1
    }
}

extension ConsentAsk {
    var connectorTitle: String {
        switch connector {
        case .calendar: "Calendar"
        case .home: "Home"
        case .reminders: "Reminders"
        case .contacts: "Contacts"
        case .location: "Location"
        case .alarms: "Alarms"
        case .shell: "Run commands"
        case .files: "Files"
        case .input: "Mouse and keyboard"
        case .apps: "Apps"
        case .clipboard: "Clipboard"
        }
    }

    var intent: String {
        switch action {
        case .calendarListEvents: "read your calendar"
        case .calendarAddEvent: "add an event to your calendar"
        case .remindersList: "read your reminders"
        case .remindersAdd: "add a reminder"
        case .remindersComplete: "mark a reminder as done"
        case .contactsSearch: "look someone up in your contacts"
        case .locationCurrent: "see where you are"
        case .locationSearchNearby: "look for places near you"
        case .alarmsSet: "set an alarm"
        case .alarmsList: "check your alarms"
        case .timersStart: "start a timer"
        case .homeListAccessories: "see your home accessories"
        case .homeSet: "change a home accessory"
        case .shellRun: "run a command on this Mac"
        case .filesRead: "read a file on this Mac"
        case .filesList: "look through a folder on this Mac"
        case .filesWrite: "change a file on this Mac"
        case .inputDisplays: "see this Mac's screen sizes"
        case .inputMove, .inputClick, .inputDrag, .inputScroll: "use this Mac's mouse"
        case .inputType, .inputKey: "use this Mac's keyboard"
        case .appsList: "see which apps are running on this Mac"
        case .appsOpen: "open an app on this Mac"
        case .appsQuit: "quit an app on this Mac"
        case .windowsList: "see which windows are open on this Mac"
        case .windowsFocus: "bring a window to the front on this Mac"
        case .clipboardRead: "read this Mac's clipboard"
        case .clipboardWrite: "change this Mac's clipboard"
        }
    }
}

@MainActor
final class DeviceHostPool {
    private static let savedKey = "dev.tsnanh.hermes.device-host-profiles"

    private let connection: ConnectionModel
    private let consent: DeviceConsentPresenter
    private let defaults: UserDefaults
    private var stacks: [String: DeviceToolStack] = [:]
    #if os(macOS)
    private var inputSafety: InputSafety?
    #endif

    init(connection: ConnectionModel, consent: DeviceConsentPresenter, defaults: UserDefaults = .standard) {
        self.connection = connection
        self.consent = consent
        self.defaults = defaults
    }

    func stack(for profile: String?) async -> DeviceToolStack? {
        let key = profile ?? ""
        if let existing = stacks[key] { return existing }
        guard let client = connection.client else { return nil }
        let stack = DeviceToolStack.make(
            connect: { try await client.connect(profile: profile, reach: .deviceHost) },
            providers: .system(),
            permissions: SystemPermissions(),
            consent: consent,
            diagnostics: .osLog()
        )
        stacks[key] = stack
        #if os(macOS)
        if inputSafety == nil {
            let safety = InputSafety { [weak self] in await self?.switchOffInput() }
            safety.start()
            inputSafety = safety
        }
        #endif
        await stack.host.start()
        return stack
    }

    func switchOffInput() async {
        for stack in stacks.values { _ = try? await stack.ledger.set(.input, state: .off) }
    }

    func stopInput() {
        #if os(macOS)
        InputController.shared.stop()
        #endif
    }

    func rearmInput() {
        #if os(macOS)
        InputController.shared.rearm()
        #endif
    }

    func remember(_ profile: String?) {
        var saved = Set(defaults.stringArray(forKey: Self.savedKey) ?? [])
        saved.insert(profile ?? "")
        defaults.set(Array(saved), forKey: Self.savedKey)
    }

    func resumeSavedHosts() async {
        for key in defaults.stringArray(forKey: Self.savedKey) ?? [] {
            _ = await stack(for: key.isEmpty ? nil : key)
        }
    }

    func reset() async {
        let running = Array(stacks.values)
        stacks.removeAll()
        for stack in running { await stack.host.stop() }
    }
}
