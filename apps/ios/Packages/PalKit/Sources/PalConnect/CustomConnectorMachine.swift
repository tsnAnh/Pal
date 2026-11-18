import Foundation

public enum CustomConnectorPhase: Sendable, Equatable {
    case idle
    case validating
    case saving
    case connecting
    case connected([ConnectorTool])
    case failed(ConnectorFailure)

    public var isInFlight: Bool {
        switch self {
        case .validating, .saving, .connecting: true
        case .idle, .connected, .failed: false
        }
    }
}

public enum CustomConnectorEvent: Sendable, Equatable {
    case submit
    case validated
    case saved
    case connected([ConnectorTool])
    case failed(ConnectorFailure)
    case reset
}

public struct CustomConnectorMachine: Sendable, Equatable {
    public private(set) var phase: CustomConnectorPhase

    public init(phase: CustomConnectorPhase = .idle) {
        self.phase = phase
    }

    @discardableResult
    public mutating func send(_ event: CustomConnectorEvent) -> Bool {
        switch (phase, event) {
        case (.idle, .submit), (.failed, .submit), (.connected, .submit):
            phase = .validating
        case (.validating, .validated):
            phase = .saving
        case (.saving, .saved):
            phase = .connecting
        case (.connecting, .connected(let tools)):
            phase = .connected(tools)
        case (.validating, .failed(let failure)), (.saving, .failed(let failure)), (.connecting, .failed(let failure)):
            phase = .failed(failure)
        case (.idle, .reset), (.failed, .reset), (.connected, .reset):
            phase = .idle
        default:
            return false
        }
        return true
    }
}
