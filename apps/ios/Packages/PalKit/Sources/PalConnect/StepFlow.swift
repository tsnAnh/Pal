import Foundation

public struct FlowStep: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case intro(youDo: String, palDoes: String)
        case instruction(openPage: SetupLink?)
        case copyCard(copies: [SetupCopy])
        case paste(fields: [SetupField])
        case browserRoundTrip(waitingTitle: String, waitingBody: String)
        case action(waitingTitle: String, waitingBody: String)
        case automatic
        case waiting(title: String, body: String)
        case success(title: String, body: String)
    }

    public var id: String
    public var title: String
    public var body: String
    public var kind: Kind
    public var primaryTitle: String?
    public var skipTitle: String?
    public var skipTarget: String?
    public var heading: String?
    public var pageLink: SetupLink?
    public var showsInChecklist: Bool
    public var allowsBack: Bool
    public var note: String?
    public var links: [SetupLink]

    public init(
        id: String, title: String, body: String = "", kind: Kind, primaryTitle: String? = nil,
        skipTitle: String? = nil, skipTarget: String? = nil, heading: String? = nil, pageLink: SetupLink? = nil,
        showsInChecklist: Bool = true, allowsBack: Bool = true, note: String? = nil, links: [SetupLink] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.kind = kind
        self.primaryTitle = primaryTitle
        self.skipTitle = skipTitle
        self.skipTarget = skipTarget
        self.heading = heading
        self.pageLink = pageLink
        self.showsInChecklist = showsInChecklist
        self.allowsBack = allowsBack
        self.note = note
        self.links = links
    }

    public var isAutomatic: Bool { kind == .automatic }

    public var screenTitle: String { heading ?? title }

    public var isChecklistRow: Bool {
        guard showsInChecklist else { return false }
        switch kind {
        case .intro, .waiting, .success: return false
        default: return true
        }
    }

    public var isIntro: Bool {
        if case .intro = kind { true } else { false }
    }

    public var isSuccess: Bool {
        if case .success = kind { true } else { false }
    }

    public var fields: [SetupField] {
        if case .paste(let fields) = kind { fields } else { [] }
    }
}

extension SetupFieldShape {
    public func message(label: String) -> String? {
        let name = label.prefix(1).lowercased() + label.dropFirst()
        switch self {
        case .empty: return nil
        case .valid: return String(localized: "Looks right")
        case .hasSpaces: return String(localized: "The \(name) can't contain spaces. Paste it again without them.")
        case .wrongStart(let prefixes):
            return String(localized: "That is not a \(name). It starts with \(prefixes.joined(separator: String(localized: " or "))). Copy it again.")
        case .wrongEnd(let suffix): return String(localized: "That is not a \(name). It ends with \(suffix). Copy it again.")
        }
    }
}

public struct StepFlowProgress: Sendable, Equatable, Codable {
    public var flowID: String
    public var stepID: String
    public var saved: [String]

    public init(flowID: String, stepID: String, saved: [String] = []) {
        self.flowID = flowID
        self.stepID = stepID
        self.saved = saved
    }
}

public protocol StepFlowProgressStore: Sendable {
    func load(flowID: String) async -> StepFlowProgress?
    func save(_ progress: StepFlowProgress) async
    func clear(flowID: String) async
}

public actor InMemoryStepFlowProgressStore: StepFlowProgressStore {
    private var entries: [String: StepFlowProgress] = [:]

    public init() {}

    public func load(flowID: String) -> StepFlowProgress? { entries[flowID] }

    public func save(_ progress: StepFlowProgress) { entries[progress.flowID] = progress }

    public func clear(flowID: String) { entries[flowID] = nil }
}

public struct StepFlowEngine: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case ready
        case working
        case failed(SetupStatus)
    }

    public enum PrimaryAction: Sendable, Equatable {
        case advance
        case work
        case finish
        case none
    }

    public enum RowState: Sendable, Equatable {
        case done
        case current
        case upcoming
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String
        public var number: Int
        public var title: String
        public var state: RowState
        public var isAutomatic: Bool
    }

    public let flowID: String
    public private(set) var steps: [FlowStep]
    public private(set) var index: Int
    public private(set) var phase: Phase = .ready
    public private(set) var saved: Set<String>
    public private(set) var values: [String: String] = [:]

    public init?(flowID: String, steps: [FlowStep], resume: StepFlowProgress? = nil) {
        guard !steps.isEmpty, Set(steps.map(\.id)).count == steps.count, steps.last?.isSuccess == true,
              steps.dropLast().allSatisfy({ !$0.isSuccess }), steps.dropFirst().allSatisfy({ !$0.isIntro })
        else { return nil }
        self.flowID = flowID
        self.steps = steps
        let known = Set(steps.flatMap(\.fields).map(\.id))
        saved = Set(resume?.saved ?? []).intersection(known)
        let restored = resume.flatMap { progress in steps.firstIndex { $0.id == progress.stepID } } ?? 0
        index = min(restored, max(steps.count - 2, 0))
    }

    public var current: FlowStep { steps[index] }

    public var isFinished: Bool { current.isSuccess }

    private var rowSteps: [FlowStep] { steps.filter(\.isChecklistRow) }

    public var stepCount: Int { rowSteps.count }

    public var stepNumber: Int {
        if isFinished { return stepCount }
        return max(steps[...index].filter(\.isChecklistRow).count, 1)
    }

    public var positionLabel: String { String(localized: "Step \(stepNumber) of \(stepCount)") }

    public var checklist: [Row] {
        rowSteps.enumerated().map { offset, step in
            let number = offset + 1
            let state: RowState = isFinished || number < stepNumber ? .done : (number == stepNumber ? .current : .upcoming)
            return Row(id: step.id, number: number, title: step.title, state: state, isAutomatic: step.isAutomatic)
        }
    }

    public var primaryAction: PrimaryAction {
        switch current.kind {
        case .intro, .instruction, .copyCard: .advance
        case .paste, .browserRoundTrip, .action: .work
        case .automatic, .waiting: .none
        case .success: .finish
        }
    }

    public var isPrimaryEnabled: Bool {
        guard phase == .ready || isFailed else { return false }
        switch primaryAction {
        case .none: return false
        case .advance, .finish: return true
        case .work: return current.fields.allSatisfy { shape(of: $0.id) == .valid }
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { true } else { false }
    }

    public var failure: SetupStatus? {
        if case .failed(let status) = phase { status } else { nil }
    }

    public func value(for fieldID: String) -> String { values[fieldID] ?? "" }

    public func shape(of fieldID: String) -> SetupFieldShape {
        guard let field = current.fields.first(where: { $0.id == fieldID }) else { return .empty }
        return field.shape(of: value(for: fieldID))
    }

    public mutating func setValue(_ text: String, for fieldID: String) {
        guard current.fields.contains(where: { $0.id == fieldID }) else { return }
        values[fieldID] = text
        if isFailed { phase = .ready }
    }

    private var previousIndex: Int? {
        guard !isFinished else { return nil }
        return (0..<index).last { !steps[$0].isAutomatic && steps[$0].isChecklistRow }
    }

    public var canGoBack: Bool { phase != .working && current.allowsBack && previousIndex != nil }

    public var canSkip: Bool {
        guard phase != .working, let target = current.skipTarget else { return false }
        return steps.contains { $0.id == target }
    }

    @discardableResult
    public mutating func advance() -> Bool {
        guard primaryAction == .advance, isPrimaryEnabled, index + 1 < steps.count else { return false }
        index += 1
        phase = .ready
        return true
    }

    @discardableResult
    public mutating func skip() -> Bool {
        guard canSkip, let target = steps.firstIndex(where: { $0.id == current.skipTarget }), target > index else { return false }
        index = target
        phase = .ready
        return true
    }

    @discardableResult
    public mutating func back() -> Bool {
        guard canGoBack, let target = previousIndex else { return false }
        index = target
        phase = .ready
        return true
    }

    @discardableResult
    public mutating func startWork() -> Bool {
        let works = primaryAction == .work || current.isAutomatic
        guard works, phase != .working, current.isAutomatic || isPrimaryEnabled else { return false }
        phase = .working
        return true
    }

    public mutating func finishWork(advance: Bool = true) {
        guard phase == .working else { return }
        saved.formUnion(current.fields.map(\.id))
        for field in current.fields { values[field.id] = nil }
        if advance { index = min(index + 1, steps.count - 1) }
        phase = .ready
    }

    public func following(steps: [FlowStep], at stepID: String, failure: SetupStatus?) -> StepFlowEngine? {
        let resume = StepFlowProgress(flowID: flowID, stepID: stepID, saved: saved.sorted())
        guard var next = StepFlowEngine(flowID: flowID, steps: steps, resume: resume) else { return nil }
        for field in next.current.fields {
            if let kept = values[field.id] { next.values[field.id] = kept }
        }
        if let failure {
            next.phase = .failed(failure)
        } else if phase == .working, next.current.id == current.id {
            next.phase = .working
        }
        return next
    }

    public mutating func fail(_ status: SetupStatus) {
        guard phase == .working else { return }
        phase = .failed(status)
    }

    public mutating func cancelWork() {
        if phase == .working { phase = .ready }
    }

    public mutating func dismissFailure() {
        if isFailed { phase = .ready }
    }

    public var progress: StepFlowProgress {
        StepFlowProgress(flowID: flowID, stepID: current.id, saved: saved.sorted())
    }
}
