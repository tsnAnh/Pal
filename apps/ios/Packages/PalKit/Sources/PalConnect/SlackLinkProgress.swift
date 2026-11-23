import Foundation

public struct SlackLinkProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case connecting
        case connected
        case failed
        case stalled
    }

    public static let fallbackReason = "Slack didn't start. Try again."

    public let phase: Phase
    public let engine: StepFlowEngine
    public let status: SetupStatus?

    public init(displayName: String, phase: Phase, reason: String?) {
        let plan = SlackSetupPlan(displayName: displayName, provider: nil, state: nil)
        guard let base = StepFlowEngine(flowID: SlackSetupPlan.flowID, steps: plan.steps) else {
            preconditionFailure("The Slack steps are always a valid flow")
        }
        let text = reason.flatMap { $0.isEmpty ? nil : $0 } ?? Self.fallbackReason
        let status: SetupStatus? = switch phase {
        case .connecting, .connected:
            nil
        case .failed:
            SetupStatus(
                kind: .internalFault, title: String(localized: "Couldn't connect"), reason: text,
                actionTitle: String(localized: "Retry"), code: "slack_link_failed"
            )
        case .stalled:
            SetupStatus(
                kind: .internalFault, title: String(localized: "Still waiting"), reason: text,
                actionTitle: String(localized: "Retry"), code: "slack_link_stalled"
            )
        }
        let engine: StepFlowEngine?
        if phase == .connected {
            engine = StepFlowEngine(flowID: SlackSetupPlan.flowID, steps: plan.steps, finished: true)
        } else {
            engine = base.following(steps: plan.steps, at: SlackSetupPlan.installingID, failure: status)
        }
        guard let engine else { preconditionFailure("The Slack steps always contain the installing and done steps") }
        self.phase = phase
        self.engine = engine
        self.status = status
    }

    public var failedRowID: String? {
        status == nil ? nil : engine.checklist.first { $0.state == .current }?.id
    }
}
