import Foundation
import PalBotProfile
import PalConnect
import PalProtocol
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
    private(set) var detail: String?
    private(set) var checkFailed = false
    private var stalled = false
    private(set) var isRechecking = false
    private(set) var tokenEntry = TokenEntry.connect
    var isEnteringTokens = false
    var confirmsDisconnect = false
    var botToken = ""
    var appToken = ""

    let botName: String
    let displayName: String
    private let services: BotsServices
    private var polling: Task<Void, Never>?

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

    private var surfaceKey: SurfaceKey { .screen("slack", bot: botName) }

    func load() async {
        guard case .loading = phase else {
            if connection == .starting, polling == nil { startPolling() }
            return
        }
        if let cached = await services.surfaces.value(SlackStatus.self, surfaceKey), case .loading = phase {
            failure = cached.failure
            detail = cached.detail
            phase = .ready(cached.connection)
        }
        await refresh()
    }

    func refresh() async {
        do {
            let status = try await services.slack.status(profile: botName)
            checkFailed = false
            show(status)
            if !status.connection.isSettled { startPolling() }
        } catch is CancellationError {
        } catch {
            failToCheck()
        }
    }

    var link: SlackLinkProgress? {
        switch phase {
        case .ready(.starting):
            SlackLinkProgress(displayName: displayName, phase: .connecting, reason: nil)
        case .ready(.connected):
            SlackLinkProgress(displayName: displayName, phase: .connected, reason: nil)
        case .ready(.failed):
            SlackLinkProgress(displayName: displayName, phase: isRechecking ? .connecting : (stalled ? .stalled : .failed), reason: detail)
        case .loading, .ready(.notConnected), .busy, .unavailable:
            nil
        }
    }

    private func failToCheck() {
        switch phase {
        case .ready(.starting):
            settle(.unreachable)
        case .ready:
            checkFailed = true
            notice = String(localized: "Couldn't refresh Slack's status. This may be out of date.")
        case .loading, .busy, .unavailable:
            phase = .unavailable
        }
    }

    func recheck() async {
        notice = nil
        checkFailed = false
        if case .ready = phase { isRechecking = true } else { phase = .busy(.checking) }
        await refresh()
        isRechecking = false
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
        let previous = Snapshot(connection: fallback, failure: failure, detail: detail)
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

    private struct Snapshot {
        let connection: SlackConnection
        let failure: SlackFailureReason?
        let detail: String?
    }

    private func restore(_ previous: Snapshot) {
        failure = previous.failure
        detail = previous.detail
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
        detail = status.detail
        stalled = false
        phase = .ready(status.connection)
        if status.connection.isSettled { services.surfaces.persist(status, surfaceKey) }
    }

    private func settle(_ status: SlackStatus, stalled: Bool = false) {
        failure = status.failure
        detail = status.detail
        self.stalled = stalled
        phase = .ready(status.connection)
    }

    private func apply(_ status: SlackStatus) {
        switch status.connection {
        case .starting: startPolling()
        case .failed:
            if status.detail == nil { notice = String(localized: "Slack saved your tokens but the connection didn't start.") }
        case .notConnected, .connected: break
        }
    }

    private func startPolling() {
        polling?.cancel()
        let slack = services.slack
        let botName = botName
        polling = Task { [weak self] in
            let outcome = await SlackStatusWatch().run(
                clock: ContinuousClock(),
                check: { try await slack.status(profile: botName) },
                onStatus: { [weak self] in self?.show($0) }
            )
            self?.finish(outcome)
        }
    }

    private func finish(_ outcome: SlackWatchOutcome) {
        switch outcome {
        case .settled(let status): apply(status)
        case .timedOut(let last): settle(.stalled(last: last, botName: displayName), stalled: true)
        case .unreachable: settle(.unreachable)
        case .cancelled: return
        }
        polling = nil
    }

    private func clearTokens() {
        botToken = ""
        appToken = ""
    }
}
