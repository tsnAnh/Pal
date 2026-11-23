import SwiftUI

public enum EscapeOutcome: Equatable, Sendable {
    case dismiss
    case confirmDiscard
    case ignore
}

public enum EscapePolicy: Equatable, Sendable {
    case dismisses
    case blocked(Reason)

    public enum Reason: String, CaseIterable, Sendable {
        case unsavedInput
        case inFlight
        case requiredStep
        case blockingError

        public var summary: String {
            switch self {
            case .unsavedInput: "typed input would be lost, so ESC asks to discard it first"
            case .inFlight: "a send, payment or irreversible operation is running, so ESC is ignored"
            case .requiredStep: "a forced sign-in or first-run step the owner has to finish"
            case .blockingError: "an error that needs a choice before anything else"
            }
        }
    }

    public init(blocking reason: Reason, when condition: Bool) {
        self = condition ? .blocked(reason) : .dismisses
    }

    public var outcome: EscapeOutcome {
        switch self {
        case .dismisses: .dismiss
        case .blocked(.unsavedInput): .confirmDiscard
        case .blocked: .ignore
        }
    }

    public var allowsClose: Bool {
        switch self {
        case .dismisses, .blocked(.unsavedInput): true
        case .blocked: false
        }
    }

    func strictest(_ other: EscapePolicy) -> EscapePolicy {
        strictness >= other.strictness ? self : other
    }

    private var strictness: Int {
        switch self {
        case .dismisses: 0
        case .blocked(.unsavedInput): 1
        case .blocked: 2
        }
    }
}

public enum EscapeLayer: Int, Comparable, Sendable, CaseIterable {
    case panel
    case stepFlow
    case sheet
    case menu
    case dialog
    case native

    public static func < (lhs: EscapeLayer, rhs: EscapeLayer) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct EscapePolicyKey: PreferenceKey {
    public static let defaultValue = EscapePolicy.dismisses

    public static func reduce(value: inout EscapePolicy, nextValue: () -> EscapePolicy) {
        value = value.strictest(nextValue())
    }
}

extension EnvironmentValues {
    @Entry public var escapeHostLayer: EscapeLayer?
}
