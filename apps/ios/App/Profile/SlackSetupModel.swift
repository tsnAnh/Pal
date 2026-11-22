import Foundation
import Observation
import PalBotProfile
import PalConnect
import PalDesign
import PalProtocol

struct SlackSetupError: Error, Sendable {
    let status: SetupStatus
}

struct GatewayOwnedProgressStore: StepFlowProgressStore {
    func load(flowID: String) async -> StepFlowProgress? { nil }
    func save(_ progress: StepFlowProgress) async {}
    func clear(flowID: String) async {}
}

extension SetupStatus {
    init(chatError error: ChatInstallClientError) {
        let fault = error.fault
        self.init(
            code: error == .unsupported ? "gateway_outdated" : error.reason.rawValue, method: fault?.method,
            trace: fault?.trace.rawValue, gatewayVersion: fault?.gatewayVersion, subject: "Slack"
        )
    }
}

@MainActor
private final class SlackRunnerBridge {
    var perform: (@MainActor (FlowStep, [String: String]) async throws -> Void)?

    func run(_ step: FlowStep, _ values: [String: String]) async throws {
        try await perform?(step, values)
    }
}

@MainActor
@Observable
final class SlackSetupModel {
    enum Stage: Equatable {
        case loading
        case flow
        case settings
        case status(SetupStatus)
    }

    let chat: ChatInstallModel
    let members: ChatMembersModel
    let flow: StepFlowModel
    let displayName: String
    private let iconPusher: ChatIconPusher
    private let spec: BotAvatarSpec?
    private(set) var finished = false
    private(set) var loaded = false
    @ObservationIgnored private var gatewayFailureShown = false
    @ObservationIgnored private var backRefusedAtRevision: Int?

    init(botName: String, displayName: String, spec: BotAvatarSpec?, client: any ChatInstallClient, members: any ChatMemberClient) {
        self.displayName = displayName
        self.spec = spec
        iconPusher = ChatIconPusher(client: client)
        chat = ChatInstallModel(botName: botName, preferredProvider: "slack", client: client)
        self.members = ChatMembersModel(client: members)
        let plan = SlackSetupPlan(displayName: displayName, provider: nil, state: nil)
        guard let engine = StepFlowEngine(flowID: SlackSetupPlan.flowID, steps: plan.steps) else {
            preconditionFailure("The Slack steps are always a valid flow")
        }
        let bridge = SlackRunnerBridge()
        flow = StepFlowModel(
            engine: engine, store: GatewayOwnedProgressStore(), advancesAfterWork: false,
            runner: { step, values in try await bridge.run(step, values) },
            classify: { ($0 as? SlackSetupError)?.status ?? SetupStatus(code: SetupStatusClass.internalFault.rawValue) }
        )
        bridge.perform = { [weak self] step, values in try await self?.run(step, values) }
        flow.recovery = { [weak self] failure in await self?.recover(failure) }
        flow.rewind = { [weak self] _, target in await self?.rewind(to: target) ?? false }
    }

    var stage: Stage {
        guard loaded else { return .loading }
        switch chat.screen {
        case .loading: return .loading
        case .unsupported: return .status(SetupStatus(code: SetupStatusClass.gatewayOutdated.rawValue, subject: "Slack"))
        case .providers: return .status(SetupStatus(code: "unsupported", subject: "Slack"))
        case .unavailable:
            return .status(chat.loadError.map(SetupStatus.init(chatError:)) ?? SetupStatus(code: SetupStatusClass.internalFault.rawValue))
        case .ready: return finished ? .settings : .flow
        default: return .flow
        }
    }

    func load() async {
        await chat.load()
        loaded = true
        finished = chat.screen == .ready
        syncAndResume()
    }

    func refresh() async {
        await chat.refresh()
        syncAndResume()
    }

    func receive(_ payload: ChatInstallChangedPayload) async {
        await chat.receive(payload)
        syncAndResume()
    }

    func loadMembers() async {
        guard let provider = chat.provider, let state = chat.state else { return }
        await members.load(scope: ChatInstallScope(provider: provider.providerId, workspace: state.workspace))
    }

    func leave(_ spaceId: String) async {
        if await members.leave(spaceId) { await chat.refreshSpaces() }
    }

    func completeFlow() {
        finished = true
    }

    func disconnect() async {
        await chat.disconnect()
        finished = false
        syncAndResume()
    }

    private func syncAndResume() {
        sync()
        if flow.engine.current.isAutomatic, flow.engine.phase == .ready {
            Task { await flow.performPrimary() }
        }
    }

    private func sync(extraFailure: SetupStatus? = nil) {
        guard chat.provider != nil, chat.state != nil else { return }
        if chat.screen != .ready { finished = false }
        let refused = backRefusedAtRevision != nil && backRefusedAtRevision == chat.state?.revision
        let plan = SlackSetupPlan(displayName: displayName, provider: chat.provider, state: chat.state, backUnavailable: refused)
        var target = plan.currentID
        let keepsBotToken = flow.engine.current.id == SlackSetupPlan.botTokenID && target == SlackSetupPlan.allowID
        if keepsBotToken, plan.steps.contains(where: { $0.id == SlackSetupPlan.botTokenID }) { target = SlackSetupPlan.botTokenID }
        let local = gatewayFailureShown ? nil : flow.engine.failure
        gatewayFailureShown = plan.failure != nil
        flow.follow(steps: plan.steps, at: target, failure: plan.failure ?? extraFailure ?? local)
    }

    private func rewind(to target: FlowStep) async -> Bool {
        guard let task = SlackSetupPlan.reopening(back: target) else { return true }
        let accepted = await chat.reopen(task)
        chat.dismissNotice()
        backRefusedAtRevision = accepted ? nil : chat.state?.revision
        sync()
        return accepted
    }

    private func recover(_ failure: SetupStatus) async {
        flow.dismissFailure()
        gatewayFailureShown = false
        guard chat.state?.step == .error else {
            if failure.kind != .vendorRefusedValue { await flow.performPrimary() }
            return
        }
        await chat.fix()
        sync(extraFailure: takeNoticeStatus())
        if flow.engine.current.isAutomatic { await flow.performPrimary() }
    }

    private func takeNoticeStatus() -> SetupStatus? {
        guard chat.notice != nil else { return nil }
        let status = chat.noticeError.map(SetupStatus.init(chatError:)) ?? SetupStatus(code: SetupStatusClass.internalFault.rawValue)
        chat.dismissNotice()
        return status
    }

    private func run(_ step: FlowStep, _ values: [String: String]) async throws {
        func value(_ id: String) -> String { (values[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch step.id {
        case SlackSetupPlan.introID:
            if let spec { await iconPusher.push(spec, onlyWhenInstalled: false) }
            await chat.begin()
        case SlackSetupPlan.credentialID:
            let refresh = value(SlackSetupPlan.refreshField)
            await chat.saveCredential(access: value(SlackSetupPlan.accessField), refresh: refresh.isEmpty ? nil : refresh)
        case SlackSetupPlan.creatingID:
            try await wait(attempts: 90, failsOnTimeout: true) { $0 == .creatingApp }
        case SlackSetupPlan.allowID:
            try await openAllowAndWait()
        case SlackSetupPlan.botTokenID:
            await chat.adoptBotToken(value(SlackSetupPlan.botTokenField))
        case SlackSetupPlan.ownerID:
            await chat.confirmOwner(value(SlackSetupPlan.memberField))
        default:
            if let task = SlackSetupPlan.guidedTasks.first(where: { SlackSetupPlan.manualID($0) == step.id }) {
                let key = task == .appLevelCredential ? value(SlackSetupPlan.appKeyField) : nil
                await chat.markDone(task, secret: key)
            }
        }
        if let status = takeNoticeStatus() { throw SlackSetupError(status: status) }
        sync()
    }

    private func openAllowAndWait() async throws {
        if let url = SlackSetupPlan.allowLink(chat.state) {
            ChatInstallReturn.remember(bot: chat.botName)
            ExternalLink.open(url)
        }
        try await wait(attempts: 300, failsOnTimeout: false) { $0 == .needsAllow }
    }

    private func wait(attempts: Int, failsOnTimeout: Bool, while holds: (ChatSetupStep) -> Bool) async throws {
        for _ in 0..<attempts {
            guard let step = chat.state?.step, holds(step) else { return }
            try await Task.sleep(for: .seconds(2))
            await chat.refresh()
            sync()
        }
        if failsOnTimeout { throw SlackSetupError(status: SetupStatus(code: "timed_out")) }
    }
}
