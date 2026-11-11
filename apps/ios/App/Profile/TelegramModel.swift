import Foundation
import HermesBotProfile
import Observation

@MainActor
@Observable
final class TelegramModel {
    enum Phase: Equatable {
        case loading
        case ready(TelegramConnection)
        case busy(Activity)
        case unavailable
    }

    enum TokenEntry: Equatable {
        case connect
        case update
    }

    enum Activity: Equatable {
        case connecting
        case disconnecting
        case checking
    }

    private(set) var phase: Phase = .loading
    private(set) var notice: String?
    private(set) var failure: TelegramFailureReason?
    private(set) var allowedUsersSet = true
    private(set) var tokenEntry = TokenEntry.connect
    var isEnteringToken = false
    var confirmsDisconnect = false
    var botToken = ""

    let botName: String
    let displayName: String
    private let services: BotsServices
    private var polling: Task<Void, Never>?

    static let pollInterval: Duration = .seconds(2)
    static let pollLimit = 8

    init(botName: String, displayName: String, services: BotsServices) {
        self.botName = botName
        self.displayName = displayName
        self.services = services
    }

    var connection: TelegramConnection? {
        if case .ready(let connection) = phase { connection } else { nil }
    }

    var canSubmitToken: Bool {
        TelegramTokenUpdate(botToken) != nil
    }

    var showsUpdateToken: Bool {
        connection?.allowsTokenUpdate == true
    }

    var showsOpenToAnyone: Bool {
        guard let connection, !allowedUsersSet else { return false }
        return connection == .connected || connection == .starting || connection == .restartNeeded
    }

    func load() async {
        guard case .loading = phase else { return }
        await refresh()
    }

    func refresh() async {
        do {
            let status = try await services.telegram.status(profile: botName)
            show(status)
            if !status.connection.isSettled { startPolling() }
        } catch is CancellationError {
        } catch {
            phase = .unavailable
        }
    }

    func recheck() async {
        phase = .busy(.checking)
        notice = nil
        await refresh()
    }

    func beginConnect() {
        guard case .ready = phase else { return }
        notice = nil
        clearToken()
        tokenEntry = .connect
        isEnteringToken = true
    }

    func beginUpdateToken() {
        guard showsUpdateToken else { return }
        notice = nil
        clearToken()
        tokenEntry = .update
        isEnteringToken = true
    }

    func cancelTokenEntry() {
        isEnteringToken = false
        clearToken()
    }

    func submitToken() async {
        guard let token = TelegramTokenUpdate(botToken) else { return }
        let fallback = tokenEntry == .update ? (connection ?? .notConnected) : .notConnected
        isEnteringToken = false
        clearToken()
        let previous = (connection: fallback, failure: failure)
        phase = .busy(.connecting)
        notice = nil
        do {
            let status = try await services.telegram.connect(profile: botName, token: token)
            show(status)
            apply(status)
        } catch is CancellationError {
        } catch BotsError.rejected(reason: TelegramService.invalidTokenReason) {
            restore(previous)
            notice = String(localized: "Telegram didn't accept that token. Check it and try again.")
        } catch BotsError.rejected(reason: TelegramService.networkReason) {
            restore(previous)
            notice = String(localized: "Couldn't reach Telegram to check the token. Check the connection and try again.")
        } catch {
            restore(previous)
            notice = String(localized: "Couldn't connect to Telegram. Try again.")
        }
    }

    func disconnect() async {
        confirmsDisconnect = false
        phase = .busy(.disconnecting)
        notice = nil
        do {
            let status = try await services.telegram.disconnect(profile: botName)
            show(status)
            apply(status)
        } catch is CancellationError {
        } catch {
            phase = .ready(.connected)
            notice = String(localized: "Couldn't disconnect Telegram. Try again.")
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
    }

    private func restore(_ previous: (connection: TelegramConnection, failure: TelegramFailureReason?)) {
        failure = previous.failure
        phase = .ready(previous.connection)
    }

    private func show(_ status: TelegramStatus) {
        failure = status.failure
        allowedUsersSet = status.allowedUsersSet
        phase = .ready(status.connection)
    }

    private func apply(_ status: TelegramStatus) {
        switch status.connection {
        case .starting: startPolling()
        case .failed:
            if status.failure == nil { notice = String(localized: "Telegram saved your token but the connection didn't start.") }
        case .restartNeeded: notice = String(localized: "Pal needs a restart to finish connecting. It can't restart while a chat is running.")
        case .notConnected, .connected: break
        }
    }

    private func startPolling() {
        polling?.cancel()
        polling = Task { [weak self] in
            for _ in 0..<Self.pollLimit {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                guard let status = try? await services.telegram.status(profile: botName) else { continue }
                show(status)
                if status.connection.isSettled {
                    apply(status)
                    return
                }
            }
        }
    }

    private func clearToken() {
        botToken = ""
    }
}
