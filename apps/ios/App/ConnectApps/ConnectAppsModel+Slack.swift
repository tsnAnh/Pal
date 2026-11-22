import PalBotProfile
import PalConnect
import PalDesign

struct SlackTarget {
    let botName: String
    let displayName: String
    let spec: BotAvatarSpec?
    let services: BotsServices
    let source: ChatInstallSource
}

extension ConnectAppsModel {
    var botInstall: ConnectBotInstall {
        switch slackStatus {
        case .needsReinstall: .needsReinstall(summary: String(localized: "Needs reinstall for a new permission"))
        case .live(let workspace):
            .installed(summary: workspace.map { String(localized: "\(botName) is live in \($0)") } ?? String(localized: "\(botName) is live in Slack"))
        case .loading, .notAdded, .unavailable: .notInstalled
        }
    }

    func loadSlack() async {
        guard let target = slackTarget else { return }
        if let status = await ProfileSlackStatus.load(botName: target.botName, source: target.source, services: target.services) {
            slackStatus = status
        }
    }

    func openSlack() {
        guard slackTarget != nil else { return }
        showsSlack = true
    }

    func closeSlack() {
        showsSlack = false
    }
}
