import Foundation
import HermesBotProfile
import Observation

@MainActor
@Observable
final class SlackModel {
    enum Phase: Equatable {
        case loading
        case ready(SlackConnection)
        case busy(Activity)
        case unavailable
    }

    enum TokenEntry: Equatable {
        case connect
        case update
    }

    enum Activity: Equatable {
        case preparing
        case connecting
        case disconnecting
        case checking
    }

    private(set) var phase: Phase = .loading
    private(set) var notice: String?
    private(set) var failure: SlackFailureReason?
    private(set) var tokenEntry = TokenEntry.connect
    var isEnteringTokens = false
    var confirmsDisconnect = false
    var botToken = ""
    var appToken = ""

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

    var connection: SlackConnection? {
        if case .ready(let connection) = phase { connection } else { nil }
    }

    var canSubmitTokens: Bool {
        SlackTokenUpdate(bot: botToken, app: appToken)?.isComplete == true
    }

    var canSubmitTokenUpdate: Bool {
        SlackTokenUpdate(bot: botToken, app: appToken) != nil
    }

    var showsUpdateTokens: Bool {
        connection?.allowsTokenUpdate == true
    }

    func load() async {
        guard case .loading = phase else { return }
        await refresh()
    }

    func refresh() async {
        do {
            let status = try await services.slack.status(profile: botName)
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

    func beginConnect() async {
        guard case .ready = phase else { return }
        phase = .busy(.preparing)
        notice = nil
        do {
            let manifest = try await services.slack.manifest(profile: botName, displayName: displayName)
            phase = .ready(connection ?? .notConnected)
            if ExternalLink.open(manifest.createURL) {
                tokenEntry = .connect
                isEnteringTokens = true
            } else {
                notice = String(localized: "Couldn't open Slack. Try again.")
            }
        } catch is CancellationError {
        } catch {
            phase = .ready(.notConnected)
            notice = String(localized: "Couldn't reach Slack. Try again.")
        }
    }

    func cancelTokenEntry() {
        isEnteringTokens = false
        clearTokens()
    }

    func beginUpdateTokens() {
        guard showsUpdateTokens else { return }
        notice = nil
        clearTokens()
        tokenEntry = .update
        isEnteringTokens = true
    }

    func submitTokens() async {
        guard let tokens = SlackTokenUpdate(bot: botToken, app: appToken), tokens.isComplete else { return }
        await send(tokens, fallback: .notConnected)
    }

    func submitTokenUpdate() async {
        guard let tokens = SlackTokenUpdate(bot: botToken, app: appToken), let fallback = connection else { return }
        await send(tokens, fallback: fallback)
    }

    private func send(_ tokens: SlackTokenUpdate, fallback: SlackConnection) async {
        isEnteringTokens = false
        clearTokens()
        let previous = (connection: fallback, failure: failure)
        phase = .busy(.connecting)
        notice = nil
        do {
            let status = try await services.slack.connect(profile: botName, tokens: tokens)
            show(status)
            apply(status)
        } catch is CancellationError {
        } catch BotsError.rejected(reason: SlackService.invalidTokensReason) {
            restore(previous)
            notice = String(localized: "Slack didn't accept those tokens. Check them and try again.")
        } catch {
            restore(previous)
            notice = String(localized: "Couldn't connect to Slack. Try again.")
        }
    }

    private func restore(_ previous: (connection: SlackConnection, failure: SlackFailureReason?)) {
        failure = previous.failure
        phase = .ready(previous.connection)
    }

    func disconnect() async {
        confirmsDisconnect = false
        phase = .busy(.disconnecting)
        notice = nil
        do {
            let status = try await services.slack.disconnect(profile: botName)
            show(status)
            apply(status)
        } catch is CancellationError {
        } catch {
            phase = .ready(.connected)
            notice = String(localized: "Couldn't disconnect Slack. Try again.")
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
    }

    private func show(_ status: SlackStatus) {
        failure = status.failure
        phase = .ready(status.connection)
    }

    private func apply(_ status: SlackStatus) {
        switch status.connection {
        case .starting: startPolling()
        case .failed:
            if status.failure == nil { notice = String(localized: "Slack saved your tokens but the connection didn't start.") }
        case .restartNeeded: notice = String(localized: "Hermes needs a restart to finish connecting. It can't restart while a chat is running.")
        case .notConnected, .connected: break
        }
    }

    private func startPolling() {
        polling?.cancel()
        polling = Task { [weak self] in
            for _ in 0..<Self.pollLimit {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                guard let status = try? await services.slack.status(profile: botName) else { continue }
                show(status)
                if status.connection.isSettled {
                    apply(status)
                    return
                }
            }
        }
    }

    private func clearTokens() {
        botToken = ""
        appToken = ""
    }
}
