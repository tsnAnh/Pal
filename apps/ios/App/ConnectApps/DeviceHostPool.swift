import Foundation
import PalClient
import PalDevice
import PalDiagnostics
import PalProtocol
import Observation
import SwiftUI

@MainActor
@Observable
final class DevicePermissionPresenter: ConsentPrompting {
    struct Pending: Identifiable {
        let id = UUID()
        let ask: ConsentAsk
        let botName: String
        let status: DeviceOSPermission
    }

    private static let representDelay: Duration = .milliseconds(400)

    private(set) var pending: Pending?
    private let botName: @MainActor (String) -> String
    private let permissions: any DevicePermissions

    init(permissions: any DevicePermissions = SystemPermissions(), botName: @escaping @MainActor (String) -> String) {
        self.permissions = permissions
        self.botName = botName
    }

    nonisolated func permissionNeeded(_ ask: ConsentAsk, status: DeviceOSPermission) {
        Task { @MainActor in self.present(ask, status: status) }
    }

    private func present(_ ask: ConsentAsk, status: DeviceOSPermission) {
        guard pending == nil else { return }
        pending = Pending(ask: ask, botName: botName(ask.profile), status: status)
    }

    func dismiss() {
        pending = nil
    }

    func accept() {
        guard let current = pending else { return }
        pending = nil
        Task { await resolve(current) }
    }

    private func resolve(_ current: Pending) async {
        if current.status == .notDetermined {
            let result = await permissions.request(current.ask.connector)
            guard result != .granted else { return }
            try? await Task.sleep(for: Self.representDelay)
            present(current.ask, status: .denied)
        } else {
            openSettings(for: current.ask.connector)
        }
    }

    private func openSettings(for connector: DeviceConnectorID) {
        let url: URL? = switch connector {
        case .input: SystemSettings.accessibilitySettingsURL
        case .messages: SystemSettings.fullDiskAccessURL
        case .screen: SystemSettings.screenRecordingURL
        default: SystemSettings.appSettingsURL
        }
        if let url { SystemSettings.open(url) }
    }
}

extension ConsentAsk {
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
        case .inputDisplays: "see your screen sizes"
        case .inputMove, .inputClick, .inputDrag, .inputScroll, .inputType, .inputKey: "control your mouse and keyboard"
        case .screenCapture: "see your screen"
        case .screenRead: "read the text on your screen"
        case .notifyPost: "show a notification on this Mac"
        case .notifyCancel: "remove a notification it showed on this Mac"
        case .appsList: "see which apps are running on this Mac"
        case .appsOpen: "open an app on this Mac"
        case .appsQuit: "quit an app on this Mac"
        case .windowsList: "see which windows are open on this Mac"
        case .windowsFocus: "bring a window to the front on this Mac"
        case .clipboardRead: "read this Mac's clipboard"
        case .clipboardWrite: "change this Mac's clipboard"
        case .messagesRecent: "see your recent messages on this Mac"
        case .messagesSearch: "search your messages on this Mac"
        case .messagesRead: "read a conversation in Messages on this Mac"
        case .messagesSend: "send a message from this Mac"
        }
    }
}

@MainActor
final class DeviceHostPool {
    private let connection: ConnectionModel
    private let consent: DevicePermissionPresenter
    private var stacks: [String: DeviceToolStack] = [:]
    #if os(macOS)
    private var inputSafety: InputSafety?
    let t3Code = T3CodeHost()
    private var t3Watch: Task<Void, Never>?
    #endif
    let screenIndicator = ScreenCaptureIndicator()

    init(connection: ConnectionModel, consent: DevicePermissionPresenter) {
        self.connection = connection
        self.consent = consent
        #if os(macOS)
        t3Code.bind { [weak self] in self?.stacks.values.map(\.host) ?? [] }
        #endif
    }

    func stack(for profile: String?) async -> DeviceToolStack? {
        let key = profile ?? ""
        if let existing = stacks[key] { return existing }
        guard let client = connection.client else { return nil }
        let stack = DeviceToolStack.make(
            connect: { try await client.connect(profile: profile, reach: .deviceHost) },
            providers: .system(screenActivity: { [screenIndicator] active in screenIndicator.report(active) }),
            permissions: SystemPermissions(),
            consent: consent,
            diagnostics: .osLog(),
            mcpRelay: mcpRelay
        )
        stacks[key] = stack
        #if os(macOS)
        if inputSafety == nil {
            let safety = InputSafety()
            safety.start()
            inputSafety = safety
        }
        #endif
        await stack.host.start()
        return stack
    }

    func startHosts(botNames: [String]) async {
        var profiles: [String?] = [nil]
        profiles += botNames
        for profile in profiles { _ = await stack(for: profile) }
        #if os(macOS)
        if t3Watch == nil {
            let controller = t3Code.controller
            t3Watch = Task { await controller.watch() }
        }
        #endif
    }

    func reset() async {
        let running = Array(stacks.values)
        stacks.removeAll()
        for stack in running { await stack.host.stop() }
        #if os(macOS)
        t3Watch?.cancel()
        t3Watch = nil
        await t3Code.bridge.closeAll()
        #endif
    }

    private var mcpRelay: (any DeviceMcpRelay)? {
        #if os(macOS)
        t3Code.bridge
        #else
        nil
        #endif
    }
}

@MainActor
@Observable
final class ScreenCaptureIndicator {
    private static let linger: Duration = .seconds(2)

    private(set) var isCapturing = false
    private var hideTask: Task<Void, Never>?

    nonisolated func report(_ active: Bool) {
        Task { @MainActor in self.apply(active) }
    }

    private func apply(_ active: Bool) {
        hideTask?.cancel()
        if active {
            isCapturing = true
            return
        }
        hideTask = Task {
            try? await Task.sleep(for: Self.linger)
            if !Task.isCancelled { isCapturing = false }
        }
    }
}

struct ScreenCaptureBadge: View {
    let indicator: ScreenCaptureIndicator

    var body: some View {
        if indicator.isCapturing {
            Label("A bot is looking at your screen", systemImage: "eye.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.red, in: Capsule())
                .padding(.top, 8)
                .accessibilityIdentifier("screenCaptureIndicator")
        }
    }
}
