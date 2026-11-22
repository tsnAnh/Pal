import Foundation

public struct InstallProgress: Sendable, Equatable {
    public var step: InstallStep
    public var completedStages: Int
    public var totalStages: Int

    public init(step: InstallStep, completedStages: Int = 0, totalStages: Int) {
        self.step = step
        self.completedStages = completedStages
        self.totalStages = max(totalStages, 1)
    }

    public var fraction: Double {
        min(max(Double(completedStages) / Double(totalStages), 0), 1)
    }

    public func status(of other: InstallStep) -> InstallStepStatus {
        if other < step { .done } else if other == step { .current } else { .pending }
    }
}

public enum InstallStepStatus: Sendable, Equatable {
    case done
    case current
    case pending
}

public enum EngineDetection: Sendable, Equatable {
    case notInstalled
    case stopped
    case running
    case ready
}

public enum LocalEngineState: Sendable, Equatable {
    public enum Process: Sendable, Equatable {
        case stopped
        case running
    }

    case detecting
    case notInstalled
    case installed(Process)
    case installing(InstallProgress)
    case removing
    case failed(EngineFailure)
    case ready

    public init(detection: EngineDetection) {
        switch detection {
        case .notInstalled: self = .notInstalled
        case .stopped: self = .installed(.stopped)
        case .running: self = .installed(.running)
        case .ready: self = .ready
        }
    }

    public var isBusy: Bool {
        switch self {
        case .detecting, .installing, .removing: true
        default: false
        }
    }

    public var failure: EngineFailure? {
        if case .failed(let failure) = self { failure } else { nil }
    }
}

public enum LocalEngineEvent: Sendable, Equatable {
    case detected(EngineDetection)
    case installBegan(step: InstallStep, totalStages: Int)
    case stageBegan(step: InstallStep, completedStages: Int)
    case installSucceeded
    case installFailed(EngineFailure)
    case installCancelled(EngineDetection)
    case removalBegan
    case removalSucceeded
    case removalFailed(EngineFailure)
    case startFailed(EngineFailure)
}

extension LocalEngineState {
    public mutating func apply(_ event: LocalEngineEvent) {
        self = reduced(by: event)
    }

    public func reduced(by event: LocalEngineEvent) -> LocalEngineState {
        switch event {
        case .detected(let detection):
            return reducedByDetection(detection)
        case .installBegan, .stageBegan, .installSucceeded, .installFailed, .installCancelled:
            return reducedByInstall(event)
        case .removalBegan, .removalSucceeded, .removalFailed:
            return reducedByRemoval(event)
        case .startFailed(let failure):
            return reducedByStartFailure(failure)
        }
    }

    private func reducedByDetection(_ detection: EngineDetection) -> LocalEngineState {
        switch self {
        case .installing, .removing: self
        default: LocalEngineState(detection: detection)
        }
    }

    private func reducedByInstall(_ event: LocalEngineEvent) -> LocalEngineState {
        if case .installBegan(let step, let total) = event {
            return canBeginInstall ? .installing(InstallProgress(step: step, totalStages: total)) : self
        }
        guard case .installing(let progress) = self else { return self }
        switch event {
        case .stageBegan(let step, let completed):
            guard step >= progress.step, completed >= progress.completedStages else { return self }
            return .installing(InstallProgress(step: step, completedStages: completed, totalStages: progress.totalStages))
        case .installSucceeded:
            return .ready
        case .installFailed(let failure):
            return .failed(failure)
        case .installCancelled(let detection):
            return LocalEngineState(detection: detection)
        default:
            return self
        }
    }

    private var canBeginInstall: Bool {
        switch self {
        case .notInstalled, .installed, .failed: true
        default: false
        }
    }

    private func reducedByRemoval(_ event: LocalEngineEvent) -> LocalEngineState {
        switch (self, event) {
        case (.ready, .removalBegan), (.installed, .removalBegan), (.failed, .removalBegan):
            .removing
        case (.removing, .removalSucceeded):
            .notInstalled
        case (.removing, .removalFailed(let failure)):
            .failed(failure)
        default:
            self
        }
    }

    private func reducedByStartFailure(_ failure: EngineFailure) -> LocalEngineState {
        switch self {
        case .ready, .installed: .failed(failure)
        default: self
        }
    }
}
