import Foundation
import PalProtocol

public struct DiscordSetupPlan: Sendable, Equatable {
    public static let flowID = "discord_bot"
    public static let startID = "start"
    public static let tokenID = "token"
    public static let serverID = "server"
    public static let inviteID = "invite"
    public static let creatingID = "creating"
    public static let doneID = "done"

    public static let tokenField = "token"
    public static let anotherServerID = "new"
    public static let guildPrefix = "guild."

    public static let invitePermissions = (1 << 4) | (1 << 10) | (1 << 11) | (1 << 15) | (1 << 16) | (1 << 29)

    public struct Inputs: Sendable, Equatable {
        public var guilds: [DiscordGuild]
        public var pickedGuildID: String?
        public var inviteURL: URL?
        public var creatingStartsItself: Bool
        public var installed: DiscordInstalled?

        public init(
            guilds: [DiscordGuild] = [], pickedGuildID: String? = nil, inviteURL: URL? = nil, creatingStartsItself: Bool = false,
            installed: DiscordInstalled? = nil
        ) {
            self.guilds = guilds
            self.pickedGuildID = pickedGuildID
            self.inviteURL = inviteURL
            self.creatingStartsItself = creatingStartsItself
            self.installed = installed
        }
    }

    public let steps: [FlowStep]

    public init(displayName name: String, _ inputs: Inputs = Inputs()) {
        steps = [
            Self.start(name),
            Self.token(),
            Self.server(inputs),
            Self.invite(name, inputs.inviteURL),
            Self.creating(name, inputs),
            Self.done(name, inputs.installed),
        ]
    }

    public func engine(finished: Bool = false, at stepID: String = startID) -> StepFlowEngine? {
        let resume = StepFlowProgress(flowID: Self.flowID, stepID: stepID)
        return StepFlowEngine(flowID: Self.flowID, steps: steps, resume: resume, finished: finished)
    }

    public static func entryStep(appExists: Bool, guilds: [DiscordGuild]) -> String {
        guard appExists else { return startID }
        return guilds.count == 1 ? creatingID : serverID
    }

    public static func inviteURL(clientID: String) -> URL? {
        var parts = URLComponents(string: "https://discord.com/oauth2/authorize")
        parts?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: "bot applications.commands"),
            URLQueryItem(name: "permissions", value: String(invitePermissions)),
            URLQueryItem(name: "integration_type", value: "0"),
        ]
        return parts?.url
    }

    public static func clientID(inCatalogInvite url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "client_id" }?.value
    }

    public static func channelURL(_ installed: DiscordInstalled) -> URL? {
        let path = [installed.guildID, installed.channelID].compactMap { $0 }.joined(separator: "/")
        return URL(string: "https://discord.com/channels/\(path)")
    }

    public static func serverSwitches(_ guilds: [DiscordGuild], picked: String?) -> [SetupSwitchGroup] {
        let soleChoice = guilds.count == 1 ? guilds[0].id : nil
        let selected = picked ?? soleChoice
        var rows = guilds.map {
            SetupSwitch(id: guildPrefix + $0.id, title: $0.name, isOn: selected == $0.id, showsInitial: true)
        }
        rows.append(SetupSwitch(
            id: anotherServerID, title: String(localized: "Another server"), subtitle: String(localized: "Pal is not here yet"),
            isOn: guilds.isEmpty, showsInitial: true
        ))
        return [SetupSwitchGroup(id: "servers", switches: rows, needsOneOn: true, exclusive: true)]
    }

    public static func pickedGuild(in values: [String: String], guilds: [DiscordGuild]) -> DiscordGuild? {
        guard let key = values.first(where: { $0.key.hasPrefix(guildPrefix) && $0.value == "1" })?.key else { return nil }
        let id = String(key.dropFirst(guildPrefix.count))
        return guilds.first { $0.id == id }
    }

    private static let developerPortal = URL(string: "https://discord.com/developers/applications")!

    private static func start(_ name: String) -> FlowStep {
        FlowStep(
            id: startID, title: String(localized: "Create the Pal app"),
            body: String(
                localized: """
                \(name) gets its own channel in your server and speaks there with its own name and picture. \
                One time on this Mac: you make the Pal app in Discord and paste its token. \
                Every other bot after that takes one tap.
                """
            ),
            kind: .instruction(openPage: nil), primaryTitle: String(localized: "Set up Pal in Discord"),
            heading: String(localized: "Add \(name) to Discord"), allowsBack: false
        )
    }

    private static func token() -> FlowStep {
        FlowStep(
            id: tokenID, title: String(localized: "Paste its token"),
            body: String(
                localized: """
                1. Open **New Application** and name it Pal.
                2. In **Bot**, press **Reset Token** and copy it.
                3. Under **Privileged Gateway Intents**, switch on **Message Content** and save.

                The token goes straight into your Vault. Pal never shows it again.
                """
            ),
            kind: .paste(fields: [DiscordFlow.tokenField]), primaryTitle: String(localized: "Check token"),
            heading: String(localized: "Paste the Pal app token"),
            pageLink: SetupLink(label: String(localized: "Open the developer portal"), url: developerPortal), inlineRefusal: true
        )
    }

    private static func server(_ inputs: Inputs) -> FlowStep {
        FlowStep(
            id: serverID, title: String(localized: "Pick the server"),
            kind: .switches(groups: serverSwitches(inputs.guilds, picked: inputs.pickedGuildID)),
            primaryTitle: String(localized: "Continue"), heading: String(localized: "Pick the server")
        )
    }

    private static func invite(_ name: String, _ link: URL?) -> FlowStep {
        FlowStep(
            id: inviteID, title: String(localized: "Invite Pal"),
            body: String(
                localized: """
                Open the link, choose the server and press Authorize. \
                Pal asks to: manage channels and webhooks, send and read messages, attach files.
                """
            ),
            kind: .openAndCheck(SetupOpenAndCheck(
                link: SetupLink(label: String(localized: "Open the invite link"), url: link ?? developerPortal),
                recheckTitle: String(localized: "Check again"), waitingTitle: String(localized: "Waiting for Discord"),
                waitingBody: String(localized: "Waiting for Discord. Pal checks by itself.")
            )),
            heading: String(localized: "Invite Pal to your server"), prepares: true
        )
    }

    private static func creating(_ name: String, _ inputs: Inputs) -> FlowStep {
        let working = String(localized: "Creating the channel and webhook for \(name)…")
        let create = String(localized: "Create \(name)'s channel")
        let server = inputs.guilds.first { $0.id == inputs.pickedGuildID }?.name
            ?? (inputs.guilds.count == 1 ? inputs.guilds[0].name : nil)
        let body = server.map { String(localized: "Pal makes a channel and a webhook for \(name) in \($0).") }
            ?? String(localized: "Pal makes a channel and a webhook for \(name).")
        return FlowStep(
            id: creatingID, title: String(localized: "Create this bot's channel"), body: body,
            kind: inputs.creatingStartsItself ? .automatic : .action(waitingTitle: working, waitingBody: ""),
            primaryTitle: create, heading: inputs.creatingStartsItself ? working : create
        )
    }

    private static func done(_ name: String, _ installed: DiscordInstalled?) -> FlowStep {
        let channel = installed?.channelName.map { "#\($0)" } ?? String(localized: "its channel")
        let server = installed?.guildName ?? String(localized: "your server")
        return FlowStep(
            id: doneID, title: String(localized: "\(name) is in Discord"),
            kind: .success(
                title: String(localized: "\(name) is in Discord"),
                body: String(
                    localized: "Write in \(channel) in \(server). Send /pal in a direct message to talk to any bot."
                )
            )
        )
    }
}
