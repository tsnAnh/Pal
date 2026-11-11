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

    enum Activity: Equatable {
        case preparing
        case connecting
        case disconnecting
        case checking
        case restarting
    }

    private(set) var phase: Phase = .loading
    private(set) var notice: String?
    var isEnteringTokens = false
    var confirmsDisconnect = false
    var botToken = ""
    var appToken = ""

    let botName: String
    let displayName: String
    private let services: BotsServices
    let hermesService: GatewayServiceModel
    private var polling: Task<Void, Never>?

    static let pollInterval: Duration = .seconds(2)
    static let pollLimit = 8

    init(botName: String, displayName: String, services: BotsServices) {
        self.botName = botName
        self.displayName = displayName
        self.services = services
        hermesService = GatewayServiceModel(client: services.gatewayService)
    }

    var connection: SlackConnection? {
        if case .ready(let connection) = phase { connection } else { nil }
    }

    var canSubmitTokens: Bool {
        SlackTokens(bot: botToken, app: appToken) != nil
    }

    func load() async {
        guard case .loading = phase else { return }
        await refresh()
    }

    func refresh() async {
        do {
            let connection = try await services.slack.status(profile: botName)
            phase = .ready(connection)
            if !connection.isSettled { startPolling() }
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

    func submitTokens() async {
        guard let tokens = SlackTokens(bot: botToken, app: appToken) else { return }
        isEnteringTokens = false
        clearTokens()
        phase = .busy(.connecting)
        notice = nil
        do {
            let connection = try await services.slack.connect(profile: botName, tokens: tokens)
            phase = .ready(connection)
            apply(connection)
        } catch is CancellationError {
        } catch BotsError.rejected(reason: SlackService.invalidTokensReason) {
            phase = .ready(.notConnected)
            notice = String(localized: "Slack didn't accept those tokens. Check them and try again.")
        } catch {
            phase = .ready(.notConnected)
            notice = String(localized: "Couldn't connect to Slack. Try again.")
        }
    }

    func disconnect() async {
        confirmsDisconnect = false
        phase = .busy(.disconnecting)
        notice = nil
        do {
            let connection = try await services.slack.disconnect(profile: botName)
            phase = .ready(connection)
            apply(connection)
        } catch is CancellationError {
        } catch {
            phase = .ready(.connected)
            notice = String(localized: "Couldn't disconnect Slack. Try again.")
        }
    }

    func restartNow() async {
        notice = nil
        phase = .busy(.restarting)
        await hermesService.restart()
        if case .restarted? = hermesService.notice {
            await refresh()
        } else {
            phase = .ready(.restartNeeded)
            notice = hermesService.noticeText
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
    }

    private func apply(_ connection: SlackConnection) {
        switch connection {
        case .starting: startPolling()
        case .failed: notice = String(localized: "Slack saved your tokens but the connection didn't start.")
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
                guard let connection = try? await services.slack.status(profile: botName) else { continue }
                phase = .ready(connection)
                if connection.isSettled {
                    apply(connection)
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
