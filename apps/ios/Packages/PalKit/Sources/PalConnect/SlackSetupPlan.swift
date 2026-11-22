import Foundation
import PalProtocol

public struct SlackSetupPlan: Sendable, Equatable {
    public static let flowID = "slack"
    public static let introID = "intro"
    public static let credentialID = "credential"
    public static let creatingID = "creating"
    public static let allowID = "allow"
    public static let installingID = "installing"
    public static let botTokenID = "bot_token"
    public static let ownerID = "owner"
    public static let channelsID = "channels"
    public static let doneID = "done"

    public static let accessField = "access"
    public static let refreshField = "refresh"
    public static let appKeyField = "app_key"
    public static let botTokenField = "bot_token"
    public static let memberField = "member_id"

    public static let guidedTasks: [ChatProviderCapability] = [.setIcon, .appLevelCredential, .gatewayRedirect]
    public static let botTokenActionID = "bot_token"

    public static func manualID(_ task: ChatProviderCapability) -> String { "manual-\(task.rawValue)" }

    public let steps: [FlowStep]
    public let currentID: String
    public let failure: SetupStatus?

    public init(displayName name: String, provider: ChatCapabilitiesWire?, state: ChatSetupStateWire?) {
        let requiresCredential = provider?.requiresConfigCredential ?? true
        let createsApp = provider?.createsApp ?? true
        let guided = Self.guidedTasks.filter { task in
            provider?.capabilities.contains { $0.capability == task && $0.mode == .guided } ?? false
        }
        let offersBotToken = state?.step == .needsAllow && state?.fallbackAction?.actionId == Self.botTokenActionID
        let again = state?.step == .revoked

        var steps = [Self.intro(name, again: again)]
        if requiresCredential { steps.append(Self.credential()) }
        if createsApp { steps.append(Self.creating(name)) }
        steps += guided.map { Self.manual($0, name: name, state: state) }
        steps.append(Self.allow(name, linked: Self.allowLink(state) != nil, offersBotToken: offersBotToken))
        steps.append(Self.installing(name))
        if offersBotToken { steps.append(Self.botToken()) }
        steps += [Self.owner(name), Self.channels(name), Self.done(name)]
        self.steps = steps

        let target = Self.target(state: state, guided: guided)
        currentID = steps.contains { $0.id == target } ? target : Self.introID
        failure = state?.step == .error
            ? state?.error.map { Self.failure($0.code, displayName: name, state: state, guided: guided) }
            : nil
    }

    private static func failure(
        _ code: ChatSetupErrorCode, displayName name: String, state: ChatSetupStateWire?, guided: [ChatProviderCapability]
    ) -> SetupStatus {
        guard code == .credentialRejected, rejectedAppKey(state, guided: guided) else { return status(for: code, displayName: name) }
        var status = SetupStatus(code: code.rawValue, subject: "Slack", valueName: "app key")
        let source = String(localized: "The app key has to come from \(name)'s own Slack app.")
        let steps = String(localized: "Open its Slack page, go to Basic Information, then App-Level Tokens, and copy a key.")
        status.reason = "\(source) \(steps)"
        return status
    }

    private static func rejectedAppKey(_ state: ChatSetupStateWire?, guided: [ChatProviderCapability]) -> Bool {
        state?.resumeStep == .needsManualStep && guided.contains(.appLevelCredential)
            && !(state?.manualStepsDone.contains(.appLevelCredential) ?? false)
    }

    public static func status(for code: ChatSetupErrorCode, displayName: String) -> SetupStatus {
        var status = SetupStatus(code: code.rawValue, subject: "Slack", valueName: "token")
        switch code {
        case .credentialExpired:
            status.title = String(localized: "Your Slack code expired")
            status.reason = String(localized: "Copy a new one from Slack and paste it here.")
        case .appCreateFailed:
            status.reason = String(localized: "Pal couldn't create \(displayName)'s Slack app. Try again in a moment.")
        case .allowDenied:
            status.title = String(localized: "Slack did not get your Allow")
            status.reason = String(localized: "Open Slack again and click Allow.")
            status.actionTitle = String(localized: "Open Slack again")
        case .installFailed:
            status.reason = String(localized: "Pal couldn't finish adding \(displayName). Try again in a moment.")
        case .providerUnreachable:
            status.title = String(localized: "Can't reach Slack")
            status.reason = String(localized: "Pal couldn't reach Slack. Check your connection, then try again.")
        case .credentialRejected, .unknown:
            break
        }
        return status
    }

    public static func allowLink(_ state: ChatSetupStateWire?) -> URL? {
        guard state?.step == .needsAllow else { return nil }
        return state?.nextAction.link.flatMap(URL.init(string:))
    }

    private static func target(state: ChatSetupStateWire?, guided: [ChatProviderCapability]) -> String {
        guard let state else { return introID }
        switch state.step {
        case .notStarted, .revoked, .unknown: return introID
        case .needsCredential: return credentialID
        case .creatingApp: return creatingID
        case .needsManualStep: return pendingTask(state, guided: guided).map(manualID) ?? allowID
        case .needsAllow: return allowID
        case .installing: return installingID
        case .needsOwner: return ownerID
        case .ready: return channelsID
        case .error: return errorTarget(state, guided: guided)
        }
    }

    private static func pendingTask(_ state: ChatSetupStateWire, guided: [ChatProviderCapability]) -> ChatProviderCapability? {
        if let named = ChatProviderCapability(rawValue: state.nextAction.actionId), guided.contains(named) { return named }
        return guided.first { !state.manualStepsDone.contains($0) }
    }

    private static func errorTarget(_ state: ChatSetupStateWire, guided: [ChatProviderCapability]) -> String {
        switch state.error?.code {
        case .credentialRejected where rejectedAppKey(state, guided: guided): manualID(.appLevelCredential)
        case .credentialRejected, .credentialExpired: credentialID
        case .appCreateFailed: creatingID
        case .allowDenied, .installFailed: allowID
        case .providerUnreachable, .unknown, nil: credentialID
        }
    }

    private static let slackAppsPage = URL(string: "https://api.slack.com/apps")

    private static func intro(_ name: String, again: Bool) -> FlowStep {
        FlowStep(
            id: introID,
            title: again ? String(localized: "Add \(name) to Slack again") : String(localized: "Add \(name) to Slack"),
            body: String(
                localized: "\(name) joins your workspace as its own member and only answers you. Setup takes about 3 minutes and you do it once per workspace."
            ),
            kind: .action(waitingTitle: String(localized: "Starting setup"), waitingBody: ""),
            primaryTitle: String(localized: "Start"), showsInChecklist: false, allowsBack: false
        )
    }

    private static func credential() -> FlowStep {
        FlowStep(
            id: credentialID, title: String(localized: "Get a Slack code"),
            body: String(
                localized: "Open Slack, sign in, find Your App Configuration Tokens, click Generate Token, choose the workspace, then copy both tokens here."
            ),
            kind: .paste(fields: [
                SetupField(id: accessField, label: String(localized: "Access token"), secret: true, prefixes: ["xoxe.xoxp-"]),
                SetupField(id: refreshField, label: String(localized: "Refresh token"), secret: true, prefixes: ["xoxe-"]),
            ]),
            primaryTitle: String(localized: "Use these tokens"),
            heading: String(localized: "Get a code from Slack"),
            pageLink: slackAppsPage.map { SetupLink(label: String(localized: "Open Slack"), url: $0) }, allowsBack: false
        )
    }

    private static func creating(_ name: String) -> FlowStep {
        FlowStep(
            id: creatingID, title: String(localized: "Create the Slack app"),
            body: String(localized: "\(name) is making the Slack app with its name and picture. This takes a few seconds."),
            kind: .automatic, heading: String(localized: "Creating \(name) in Slack"), allowsBack: false
        )
    }

    private static func manual(_ task: ChatProviderCapability, name: String, state: ChatSetupStateWire?) -> FlowStep {
        let link = state.flatMap { $0.nextAction.actionId == task.rawValue ? $0.nextAction.link : nil }
            .flatMap(URL.init(string:)).map { SetupLink(label: String(localized: "Open the Slack page"), url: $0) }
        let done = String(localized: "Done")
        let saving = FlowStep.Kind.action(waitingTitle: String(localized: "Saving"), waitingBody: "")
        switch task {
        case .appLevelCredential:
            return FlowStep(
                id: manualID(task), title: String(localized: "Copy the app key"),
                body: String(
                    localized: "Open the Slack page, click Generate Token and Scopes under App-Level Tokens, add connections:write, then Copy and come back."
                ),
                kind: .paste(fields: [SetupField(id: appKeyField, label: String(localized: "App key"), secret: true, prefixes: ["xapp-"])]),
                primaryTitle: done, pageLink: link, allowsBack: false
            )
        case .gatewayRedirect:
            return FlowStep(
                id: manualID(task), title: String(localized: "Add Pal's return address"),
                body: String(localized: "Open the Slack page, add this address under Redirect URLs, then click Save URLs."),
                kind: saving, primaryTitle: done, pageLink: link, allowsBack: false
            )
        default:
            return FlowStep(
                id: manualID(task), title: String(localized: "Add \(name)'s picture"),
                body: String(
                    localized: "Slack doesn't let apps set their own picture. Save it, open the Slack page, and upload it under Display Information."
                ),
                kind: saving, primaryTitle: done, pageLink: link, allowsBack: false
            )
        }
    }

    private static func allow(_ name: String, linked: Bool, offersBotToken: Bool) -> FlowStep {
        FlowStep(
            id: allowID, title: String(localized: "Click Allow"),
            body: String(localized: "A browser window opens with \(name)'s Slack app. Click Allow, and you come back here."),
            kind: .browserRoundTrip(
                waitingTitle: String(localized: "Waiting for Slack"),
                waitingBody: String(
                    localized: "Click Allow in the browser window, then come back to Pal. If your workspace needs an admin to approve it, ask them."
                )
            ),
            primaryTitle: linked ? String(localized: "Open Slack to allow") : String(localized: "Check again"),
            skipTitle: offersBotToken ? String(localized: "Paste a bot token instead") : nil,
            skipTarget: offersBotToken ? botTokenID : nil,
            heading: String(localized: "Click Allow in Slack"), allowsBack: false
        )
    }

    private static func installing(_ name: String) -> FlowStep {
        FlowStep(
            id: installingID, title: String(localized: "Finish adding \(name)"),
            kind: .waiting(
                title: String(localized: "Finishing in Slack"),
                body: String(localized: "\(name) is joining your workspace. This takes a few seconds.")
            )
        )
    }

    private static func botToken() -> FlowStep {
        FlowStep(
            id: botTokenID, title: String(localized: "Paste a bot token"),
            body: String(localized: "Use the bot token from your own Slack app instead of clicking Allow."),
            kind: .paste(fields: [SetupField(id: botTokenField, label: String(localized: "Bot token"), secret: true, prefixes: ["xoxb-"])]),
            primaryTitle: String(localized: "Use this token"), showsInChecklist: false
        )
    }

    private static func owner(_ name: String) -> FlowStep {
        FlowStep(
            id: ownerID, title: String(localized: "Who are you?"),
            body: String(localized: "\(name) only answers you. Enter your Slack member ID so it knows who you are."),
            kind: .paste(fields: [SetupField(id: memberField, label: String(localized: "Slack member ID"), prefixes: ["U", "W"])]),
            primaryTitle: String(localized: "Next"), heading: String(localized: "Which Slack member are you?"), allowsBack: false
        )
    }

    private static func channels(_ name: String) -> FlowStep {
        FlowStep(
            id: channelsID, title: String(localized: "Pick channels"), kind: .instruction(openPage: nil),
            primaryTitle: String(localized: "Finish"), heading: String(localized: "Which channels should \(name) join?"), allowsBack: false
        )
    }

    private static func done(_ name: String) -> FlowStep {
        FlowStep(
            id: doneID, title: String(localized: "\(name) is in Slack"),
            kind: .success(title: String(localized: "\(name) is in Slack"), body: String(localized: "You can DM or @mention \(name) in Slack."))
        )
    }
}
