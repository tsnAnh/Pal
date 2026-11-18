import Foundation

public enum DiscordFlow {
    public static let flowID = "discord"

    public enum StepID {
        public static let bot = "bot"
        public static let token = "token"
        public static let intents = "intents"
        public static let invite = "invite"
        public static let access = "access"
        public static let done = "done"
    }

    public static let readOnlyID = "read_only"
    public static let guildPrefix = "guild."
    static let gatewayInviteStep = "invite"

    private static let developerPortal = URL(string: "https://discord.com/developers/applications")!
    private static let authorizeBase = URL(string: "https://discord.com/oauth2/authorize")!

    public static let tokenField = SetupField(id: "token", label: String(localized: "Bot token"), secret: true, dottedParts: 3)

    static let tokenStep = SetupStep(id: StepID.token, kind: .paste, title: "", fields: [tokenField], check: .discordBot)

    public static func steps() -> [FlowStep] {
        [
            FlowStep(
                id: StepID.bot, title: String(localized: "Create your Discord bot"), rowTitle: String(localized: "Create the bot"),
                body: String(localized: "You make the bot in Discord's developer portal once. Pal opens the page for you."),
                kind: .instruction(openPage: SetupLink(label: String(localized: "Open Discord developer portal"), url: developerPortal))
            ),
            FlowStep(
                id: StepID.token, title: String(localized: "Paste the bot token"), rowTitle: String(localized: "Paste the token"),
                body: String(localized: "In the portal open **Bot**, then **Reset Token** and copy it."),
                kind: .paste(fields: [tokenField]), primaryTitle: String(localized: "Check token"), inlineRefusal: true
            ),
            FlowStep(
                id: StepID.intents, title: String(localized: "Turn on Message Content"), rowTitle: String(localized: "Turn on intents"),
                body: String(
                    localized: "On the same Bot page, under **Privileged Gateway Intents**, switch it on and save, then tick the box here."
                ),
                kind: .confirm(items: [
                    SetupConfirmItem(
                        id: "message_content", title: String(localized: "Message Content Intent"),
                        subtitle: String(localized: "So Pal can read messages it is shown")
                    ),
                ])
            ),
            FlowStep(
                id: StepID.invite, title: String(localized: "Invite your bot to a server"), rowTitle: String(localized: "Invite to servers"),
                body: String(localized: "Open the link, choose the server, click **Authorize**. Pal checks that the bot is there."),
                kind: .openAndCheck(SetupOpenAndCheck(
                    link: SetupLink(label: String(localized: "Open invite link"), url: authorizeBase), recheckTitle: String(localized: "Check again"),
                    waitingTitle: String(localized: "Waiting for Discord"),
                    waitingBody: String(localized: "Choose the server and click Authorize in your browser. Pal checks by itself.")
                )),
                prepares: true
            ),
            FlowStep(
                id: StepID.access, title: String(localized: "What may the bot do?"), rowTitle: String(localized: "Choose what it may do"),
                kind: .switches(groups: []), primaryTitle: String(localized: "Finish"), prepares: true,
                workingTitle: String(localized: "Starting Discord on your Pal"),
                workingBody: String(localized: "This takes a moment. You can leave this open.")
            ),
            FlowStep(
                id: StepID.done, title: String(localized: "Discord is connected"),
                kind: .success(
                    title: String(localized: "Discord is connected"),
                    body: String(localized: "Pal can use the servers you picked. You can change this any time from Connect Apps.")
                )
            ),
        ]
    }

    public static func resume(from progress: SetupProgress?) -> StepFlowProgress? {
        guard let progress else { return nil }
        let step: String = switch progress.stepID {
        case "token": StepID.token
        case gatewayInviteStep: StepID.intents
        case "servers", "access": StepID.access
        default: StepID.bot
        }
        return StepFlowProgress(flowID: flowID, stepID: step, saved: progress.saved)
    }

    public static func engine(resume: SetupProgress?) -> StepFlowEngine? {
        StepFlowEngine(flowID: flowID, steps: steps(), resume: Self.resume(from: resume))
    }

    public static let notInServer: SetupStatus = {
        var status = SetupStatus(code: "bot_not_in_server", method: "connectors.discord.guilds", subject: "Discord")
        status.title = String(localized: "The bot isn't in a server yet")
        status.reason = String(localized: "Open the invite link, choose a server and click Authorize. Then check again.")
        status.actionTitle = String(localized: "Check again")
        return status
    }()
}

public struct DiscordFlowRunner: Sendable {
    public struct Timing: Sendable {
        public var interval: Duration
        public var attempts: Int

        public init(interval: Duration = .seconds(3), attempts: Int = 30) {
            self.interval = interval
            self.attempts = max(attempts, 1)
        }
    }

    private let service: ConnectAppsService
    private let entry: PalCatalogEntry
    private let timing: Timing

    public init(service: ConnectAppsService, entry: PalCatalogEntry, timing: Timing = Timing()) {
        self.service = service
        self.entry = entry
        self.timing = timing
    }

    public func run(_ step: FlowStep, values: [String: String]) async throws {
        switch step.id {
        case DiscordFlow.StepID.token: try await saveToken(values[DiscordFlow.tokenField.id] ?? "")
        case DiscordFlow.StepID.invite: try await waitForServer()
        case DiscordFlow.StepID.access: try await saveAccess(values)
        default: break
        }
    }

    public func prepare(_ step: FlowStep) async throws -> FlowStep.Kind? {
        switch step.id {
        case DiscordFlow.StepID.invite: try await inviteKind(for: step)
        case DiscordFlow.StepID.access: try await accessKind()
        default: nil
        }
    }

    public func classify(_ error: any Error) -> SetupStatus {
        var status = SetupStatus(error: error, subject: "Discord", valueName: "token")
        switch status.kind {
        case .vendorRefusedValue:
            status.reason = String(localized: "Copy it again from the Bot page. A token is three parts joined by dots.")
        case .internalFault where status.code.lowercased() == "check_unavailable":
            status.title = String(localized: "Pal couldn't reach Discord")
            status.reason = String(localized: "Discord didn't answer. Try again in a moment.")
        default: break
        }
        return status
    }

    private func saveToken(_ token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let verification = try await service.verifySetup(entry, step: DiscordFlow.tokenStep, values: [DiscordFlow.tokenField.id: trimmed])
        guard verification.result.ok else {
            let code = verification.result.failure(appName: "Discord").code.lowercased()
            throw SetupStatusError(SetupStatus(code: code, method: "connectors.setup.check", subject: "Discord", valueName: "token"))
        }
        _ = try await service.saveDiscordToken(verification)
    }

    private func waitForServer() async throws {
        for attempt in 0..<timing.attempts {
            if !(try await service.discordServers()).guilds.isEmpty { return }
            if attempt + 1 < timing.attempts { try await Task.sleep(for: timing.interval) }
        }
        throw SetupStatusError(DiscordFlow.notInServer)
    }

    private func saveAccess(_ values: [String: String]) async throws {
        let ids = values.compactMap { key, value -> String? in
            guard key.hasPrefix(DiscordFlow.guildPrefix), value == "1" else { return nil }
            return String(key.dropFirst(DiscordFlow.guildPrefix.count))
        }
        try await service.saveDiscord(guildIDs: ids.sorted(), readOnly: values[DiscordFlow.readOnlyID] != "0")
    }

    private func inviteKind(for step: FlowStep) async throws -> FlowStep.Kind {
        guard case .openAndCheck(let current) = step.kind else { throw SetupStatusError(SetupStatus(code: "internal")) }
        let fresh = try await service.catalogEntry(slug: entry.slug)
        let links = fresh?.setupGuide?.steps.first { $0.id == DiscordFlow.gatewayInviteStep }?.links ?? []
        guard let first = links.first else {
            throw SetupStatusError(SetupStatus(code: "gateway_outdated", method: "connectors.catalog", subject: "Discord"))
        }
        var open = current
        open.link = SetupLink(label: current.link.label, url: first.url)
        open.copies = links.map { SetupCopy(label: $0.label, value: $0.url.absoluteString) }
        return .openAndCheck(open)
    }

    private func accessKind() async throws -> FlowStep.Kind {
        let servers = try await service.discordServers()
        let allowed = Set(servers.allowed)
        let readOnly = SetupSwitch(
            id: DiscordFlow.readOnlyID, title: String(localized: "Read only"), subtitle: String(localized: "It can read, never post"),
            subtitleWhenOff: String(localized: "It can read, post, react and delete as itself"), isOn: servers.readOnly,
            confirmTurningOff: SetupConfirmation(
                title: String(localized: "Let the bot post?"),
                message: String(localized: "The bot can post, react and delete messages as itself in the servers you picked."),
                confirmTitle: String(localized: "Allow posting")
            )
        )
        let guilds = servers.guilds.map {
            SetupSwitch(id: DiscordFlow.guildPrefix + $0.id, title: $0.name, isOn: allowed.contains($0.id))
        }
        return .switches(groups: [
            SetupSwitchGroup(id: "access", switches: [readOnly]),
            SetupSwitchGroup(
                id: "servers", header: String(localized: "Servers it may use"), switches: guilds, needsOneOn: true,
                emptyNote: String(localized: "The bot isn't in any server yet. Go back and open the invite link.")
            ),
        ])
    }
}
