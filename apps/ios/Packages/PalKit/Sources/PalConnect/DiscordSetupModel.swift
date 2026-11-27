import Foundation
import Observation
import PalTransport

public struct DiscordInstalled: Sendable, Equatable {
    public var guildID: String
    public var guildName: String
    public var channelID: String?
    public var channelName: String?

    public init(guildID: String, guildName: String, channelID: String? = nil, channelName: String? = nil) {
        self.guildID = guildID
        self.guildName = guildName
        self.channelID = channelID
        self.channelName = channelName
    }
}

public enum DiscordInstallOutcome: Sendable, Equatable {
    case installed(DiscordInstalled)
    case needsOwner
}

public protocol DiscordSetupGateway: Sendable {
    func appExists() async throws -> Bool
    func saveToken(_ token: String) async throws
    func servers() async throws -> [DiscordGuild]
    func inviteURL() async throws -> URL
    func existingInstall(in guilds: [DiscordGuild]) async throws -> DiscordInstalled?
    func install(in guild: DiscordGuild) async throws -> DiscordInstallOutcome
    func confirmOwner(_ userID: String, in guild: DiscordGuild) async throws -> DiscordInstallOutcome
}

@MainActor
private final class DiscordRunnerBridge {
    var performRun: (@MainActor (FlowStep, [String: String]) async throws -> Void)?
    var performPrepare: (@MainActor (FlowStep) async throws -> FlowStep.Kind?)?

    func run(_ step: FlowStep, _ values: [String: String]) async throws {
        try await performRun?(step, values)
    }

    func prepare(_ step: FlowStep) async throws -> FlowStep.Kind? {
        try await performPrepare?(step)
    }
}

@MainActor
@Observable
public final class DiscordSetupModel {
    public enum Stage: Equatable {
        case loading
        case flow
        case status(SetupStatus)
    }

    public struct Timing: Sendable {
        public var interval: Duration
        public var attempts: Int
        public var limits: SetupLimits

        public init(interval: Duration = .seconds(2), attempts: Int = 30, limits: SetupLimits = SetupLimits()) {
            self.interval = interval
            self.attempts = max(attempts, 1)
            self.limits = limits
        }
    }

    public let displayName: String
    public private(set) var flow: StepFlowModel
    public private(set) var stage = Stage.loading
    public private(set) var installed: DiscordInstalled?
    @ObservationIgnored private var inputs = DiscordSetupPlan.Inputs()
    @ObservationIgnored private let gateway: any DiscordSetupGateway
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private let bridge = DiscordRunnerBridge()

    public init(displayName: String, gateway: any DiscordSetupGateway, timing: Timing = Timing()) {
        self.displayName = displayName
        self.gateway = gateway
        self.timing = timing
        guard let engine = DiscordSetupPlan(displayName: displayName).engine() else {
            preconditionFailure("The Discord steps are always a valid flow")
        }
        flow = Self.makeFlow(engine, bridge: bridge, limits: timing.limits)
        wire(flow)
    }

    private static func makeFlow(_ engine: StepFlowEngine, bridge: DiscordRunnerBridge, limits: SetupLimits) -> StepFlowModel {
        StepFlowModel(
            engine: engine, advancesAfterWork: false,
            runner: { step, values in try await bridge.run(step, values) },
            classify: { Self.status(for: $0) },
            prepare: { step in try await bridge.prepare(step) },
            limits: limits
        )
    }

    private func wire(_ model: StepFlowModel) {
        bridge.performRun = { [weak self] step, values in try await self?.run(step, values) }
        bridge.performPrepare = { [weak self] step in try await self?.prepare(step) }
        model.recovery = { [weak self] failure in await self?.recover(failure) }
    }

    nonisolated static func status(for error: any Error) -> SetupStatus {
        if error is DeadlineExceeded { return .tookTooLong }
        return (error as? SetupStatusError)?.status ?? SetupStatus(error: error, subject: "Discord", valueName: "token")
    }

    public func load() async {
        stage = .loading
        do {
            let gateway = gateway
            let limits = timing.limits
            let exists = try await Deadline.run(limits.call) { try await gateway.appExists() }
            let guilds = exists ? try await Deadline.run(limits.call) { try await gateway.servers() } : []
            let known = guilds
            if exists, let done = try await Deadline.run(limits.step, { try await gateway.existingInstall(in: known) }) {
                finish(done)
                return
            }
            inputs.guilds = guilds
            inputs.pickedGuildID = guilds.count == 1 ? guilds[0].id : nil
            stage = .flow
            go(DiscordSetupPlan.entryStep(appExists: exists, guilds: guilds))
        } catch {
            stage = .status(Self.status(for: error))
        }
    }

    private func go(_ target: String) {
        let plan = DiscordSetupPlan(displayName: displayName, inputs)
        flow.follow(steps: plan.steps, at: target, failure: nil)
    }

    private func finish(_ done: DiscordInstalled) {
        installed = done
        inputs.installed = done
        guard let engine = DiscordSetupPlan(displayName: displayName, inputs).engine(finished: true) else { return }
        flow = Self.makeFlow(engine, bridge: bridge, limits: timing.limits)
        wire(flow)
        stage = .flow
    }

    private func prepare(_ step: FlowStep) async throws -> FlowStep.Kind? {
        guard step.id == DiscordSetupPlan.inviteID else { return nil }
        inputs.inviteURL = try await gateway.inviteURL()
        return DiscordSetupPlan(displayName: displayName, inputs).steps.first { $0.id == step.id }?.kind
    }

    private func run(_ step: FlowStep, _ values: [String: String]) async throws {
        switch step.id {
        case DiscordSetupPlan.tokenID:
            try await gateway.saveToken(values[DiscordSetupPlan.tokenField] ?? "")
            inputs.guilds = try await gateway.servers()
            go(DiscordSetupPlan.serverID)
        case DiscordSetupPlan.serverID:
            if let guild = DiscordSetupPlan.pickedGuild(in: values, guilds: inputs.guilds) {
                inputs.pickedGuildID = guild.id
                inputs.creatingStartsItself = true
                go(DiscordSetupPlan.creatingID)
            } else {
                inputs.pickedGuildID = nil
                go(DiscordSetupPlan.inviteID)
            }
        case DiscordSetupPlan.inviteID:
            let guild = try await waitForNewServer()
            inputs.pickedGuildID = guild.id
            inputs.creatingStartsItself = true
            go(DiscordSetupPlan.creatingID)
        case DiscordSetupPlan.creatingID:
            guard let guild = pickedGuild else {
                go(DiscordSetupPlan.serverID)
                return
            }
            settle(try await gateway.install(in: guild))
        case DiscordSetupPlan.ownerID:
            guard let guild = pickedGuild else {
                go(DiscordSetupPlan.serverID)
                return
            }
            let userID = (values[DiscordSetupPlan.ownerField] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            settle(try await gateway.confirmOwner(userID, in: guild))
        default:
            break
        }
    }

    private var pickedGuild: DiscordGuild? {
        inputs.guilds.first { $0.id == inputs.pickedGuildID }
    }

    private func settle(_ outcome: DiscordInstallOutcome) {
        switch outcome {
        case .installed(let done):
            finish(done)
        case .needsOwner:
            inputs.asksOwner = true
            go(DiscordSetupPlan.ownerID)
        }
    }

    private func waitForNewServer() async throws -> DiscordGuild {
        let known = Set(inputs.guilds.map(\.id))
        for attempt in 0..<timing.attempts {
            let current = try await gateway.servers()
            if let fresh = current.first(where: { !known.contains($0.id) }) {
                inputs.guilds = current
                return fresh
            }
            if attempt + 1 < timing.attempts { try await Task.sleep(for: timing.interval) }
        }
        throw SetupStatusError(DiscordSetupPlan.inviteTimeout(server: nil, invite: inputs.inviteURL))
    }

    private func recover(_ failure: SetupStatus) async {
        let onCreating = flow.engine.current.id == DiscordSetupPlan.creatingID
        switch failure.code {
        case "invalid_token", "no_token":
            flow.dismissFailure()
            go(DiscordSetupPlan.tokenID)
        case DiscordSetupPlan.inviteTimeoutCode where onCreating:
            flow.dismissFailure()
            inputs.pickedGuildID = nil
            go(DiscordSetupPlan.inviteID)
            await flow.retryAfterFailure()
        default:
            await flow.retryAfterFailure()
        }
    }
}
