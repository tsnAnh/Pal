import Foundation
import PalBotProfile
import PalConnect
import PalDesign

enum OAuthClientCardText {
    static func actionTitle(_ state: ConnectAppState) -> String {
        switch state {
        case .needsSetup: String(localized: "Set up")
        case .disconnected: String(localized: "Connect")
        case .needsAuthorization: String(localized: "Reconnect")
        case .connected: String(localized: "Remove")
        }
    }

    static func prominent(_ state: ConnectAppState) -> Bool {
        state == .needsSetup || state == .needsAuthorization
    }
}

extension ConnectAppsModel {
    func oauthClientAction(_ app: ConnectApp) {
        switch app.state {
        case .needsSetup: presentOAuthClient(app, problem: nil)
        case .disconnected, .needsAuthorization: Task { await connectOAuthClient(app) }
        case .connected: disconnectTarget = .app(app)
        }
    }

    func presentOAuthClient(_ app: ConnectApp, problem: OAuthClientProblem?) {
        guard let entry = app.oauthClientEntry else { return }
        if app.setupGuideEntry != nil {
            presentSetupGuide(app, problem: problem)
            return
        }
        oauthClientSheet = OAuthClientSheetModel(
            app: app, entry: entry, service: service, problem: problem,
            connectAgain: { [weak self] in
                self?.oauthClientSheet = nil
                Task { await self?.connectOAuthClient(app) }
            },
            finished: { [weak self] in
                self?.oauthClientSheet = nil
                await self?.reload()
            }
        )
    }

    func connectOAuthClient(_ app: ConnectApp) async {
        guard let entry = app.oauthClientEntry, !busy.contains(app.id) else { return }
        busy.insert(app.id)
        defer { busy.remove(app.id) }
        do {
            let route = McpConnectRoute.decide(requires: [], platform: ConnectorPlatform.current)
            if case .paste(let session) = try await service.connectOAuthClient(entry, route: route) {
                await presentOAuthClientPaste(session, app: app)
            }
        } catch {
            if (error as? ConnectAppsError) != .cancelled { presentOAuthClient(app, problem: OAuthClientProblem(connecting: error)) }
        }
        await reload()
    }

    private func presentOAuthClientPaste(_ session: any McpPasteSigning, app: ConnectApp) async {
        guard pasteSession == nil else {
            await session.cancel()
            return
        }
        guard ExternalLink.open(session.authorizeURL) else {
            await session.cancel()
            let unavailable = ConnectAppsError.signInFailed(McpOAuthError.browserUnavailable.reason)
            presentOAuthClient(app, problem: OAuthClientProblem(unavailable, retry: .connect))
            return
        }
        pasteSession = session
        pasteTargetID = app.id
        pasteState = .idle
        pastingApp = app
    }
}

extension ConnectAppsModel {
    var slackStatus: ConnectRowStatus {
        ConnectRowStatus(slack.summary, tone: slack.needsReinstall ? .attention : slack.installedCount > 0 ? .positive : .neutral)
    }

    var slackActionTitle: String {
        slack.installedCount > 0 ? String(localized: "Manage") : String(localized: "Set up")
    }

    func closeSlackPicker() {
        showsSlackPicker = false
        Task { await slack.load() }
    }
}
