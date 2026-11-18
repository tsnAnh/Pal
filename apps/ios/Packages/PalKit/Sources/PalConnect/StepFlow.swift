import Foundation
import Observation

public struct FlowStep: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case instruction(openPage: SetupLink?)
        case copyCard(copies: [SetupCopy])
        case paste(fields: [SetupField])
        case browserRoundTrip(waitingTitle: String, waitingBody: String)
        case confirm(items: [SetupConfirmItem])
        case openAndCheck(SetupOpenAndCheck)
        case switches(groups: [SetupSwitchGroup])
        case automatic
        case waiting(title: String, body: String)
        case success(title: String, body: String)
    }

    public var id: String
    public var title: String
    public var rowTitle: String?
    public var body: String
    public var kind: Kind
    public var primaryTitle: String?
    public var skipTitle: String?
    public var skipTarget: String?
    public var prepares: Bool
    public var inlineRefusal: Bool
    public var workingTitle: String?
    public var workingBody: String

    public init(
        id: String, title: String, rowTitle: String? = nil, body: String = "", kind: Kind, primaryTitle: String? = nil,
        skipTitle: String? = nil, skipTarget: String? = nil, prepares: Bool = false, inlineRefusal: Bool = false,
        workingTitle: String? = nil, workingBody: String = ""
    ) {
        self.id = id
        self.title = title
        self.rowTitle = rowTitle
        self.body = body
        self.kind = kind
        self.primaryTitle = primaryTitle
        self.skipTitle = skipTitle
        self.skipTarget = skipTarget
        self.prepares = prepares
        self.inlineRefusal = inlineRefusal
        self.workingTitle = workingTitle
        self.workingBody = workingBody
    }

    public var isAutomatic: Bool { kind == .automatic }

    public var isChecklistRow: Bool {
        switch kind {
        case .waiting, .success: false
        default: true
        }
    }

    public var isSuccess: Bool {
        if case .success = kind { true } else { false }
    }

    public var fields: [SetupField] {
        if case .paste(let fields) = kind { fields } else { [] }
    }
}

extension SetupFieldShape {
    private static func spelledOut(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en")
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }

    public func message(label: String) -> String? {
        let name = label.prefix(1).lowercased() + label.dropFirst()
        switch self {
        case .empty: return nil
        case .valid: return String(localized: "Looks right")
        case .hasSpaces: return String(localized: "The \(name) can't contain spaces. Paste it again without them.")
        case .wrongStart(let prefixes):
            return String(localized: "That is not a \(name). It starts with \(prefixes.joined(separator: String(localized: " or "))). Copy it again.")
        case .wrongEnd(let suffix): return String(localized: "That is not a \(name). It ends with \(suffix). Copy it again.")
        case .wrongParts(let count):
            let spelled = Self.spelledOut(count)
            return String(localized: "That is not a \(name). A \(name) is \(spelled) parts joined by dots. Copy it again.")
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
        case preparing
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
    public private(set) var confirmed: Set<String> = []
    public private(set) var switches: [String: Bool] = [:]

    public init?(flowID: String, steps: [FlowStep], resume: StepFlowProgress? = nil) {
        guard !steps.isEmpty, Set(steps.map(\.id)).count == steps.count, steps.last?.isSuccess == true,
              steps.dropLast().allSatisfy({ !$0.isSuccess })
        else { return nil }
        self.flowID = flowID
        self.steps = steps
        let known = Set(steps.flatMap(\.fields).map(\.id))
        saved = Set(resume?.saved ?? []).intersection(known)
        let restored = resume.flatMap { progress in steps.firstIndex { $0.id == progress.stepID } } ?? 0
        index = min(restored, max(steps.count - 2, 0))
        for step in steps { seedSwitches(step.kind) }
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
            return Row(id: step.id, number: number, title: step.rowTitle ?? step.title, state: state, isAutomatic: step.isAutomatic)
        }
    }

    public var primaryAction: PrimaryAction {
        switch current.kind {
        case .instruction, .copyCard, .confirm: .advance
        case .paste, .browserRoundTrip, .openAndCheck, .switches: .work
        case .automatic, .waiting: .none
        case .success: .finish
        }
    }

    public var isPrimaryEnabled: Bool {
        guard phase == .ready || isFailed else { return false }
        switch primaryAction {
        case .none: return false
        case .finish: return true
        case .advance, .work: return isStepComplete
        }
    }

    private var isStepComplete: Bool {
        switch current.kind {
        case .confirm(let items): items.allSatisfy { confirmed.contains($0.id) }
        case .switches(let groups): !groups.isEmpty && groups.allSatisfy { !$0.needsOneOn || $0.switches.contains { isOn($0.id) } }
        default: current.fields.allSatisfy { shape(of: $0.id) == .valid }
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { true } else { false }
    }

    public var failure: SetupStatus? {
        if case .failed(let status) = phase { status } else { nil }
    }

    public func value(for fieldID: String) -> String { values[fieldID] ?? "" }

    public func isConfirmed(_ id: String) -> Bool { confirmed.contains(id) }

    public func isOn(_ id: String) -> Bool { switches[id] ?? false }

    public var workValues: [String: String] {
        values.merging(switches.mapValues { $0 ? "1" : "0" }) { field, _ in field }
    }

    public func shape(of fieldID: String) -> SetupFieldShape {
        guard let field = current.fields.first(where: { $0.id == fieldID }) else { return .empty }
        return field.shape(of: value(for: fieldID))
    }

    public mutating func setValue(_ text: String, for fieldID: String) {
        guard current.fields.contains(where: { $0.id == fieldID }) else { return }
        values[fieldID] = text
        if isFailed { phase = .ready }
    }

    public mutating func setConfirmed(_ id: String, _ on: Bool) {
        guard case .confirm(let items) = current.kind, items.contains(where: { $0.id == id }) else { return }
        if on { confirmed.insert(id) } else { confirmed.remove(id) }
        if isFailed { phase = .ready }
    }

    public mutating func setSwitch(_ id: String, _ on: Bool) {
        guard case .switches(let groups) = current.kind, groups.contains(where: { $0.switches.contains { $0.id == id } }) else { return }
        switches[id] = on
        if isFailed { phase = .ready }
    }

    private mutating func seedSwitches(_ kind: FlowStep.Kind) {
        guard case .switches(let groups) = kind else { return }
        for group in groups { for item in group.switches { switches[item.id] = item.isOn } }
    }

    @discardableResult
    public mutating func replaceKind(of stepID: String, with kind: FlowStep.Kind) -> Bool {
        guard let position = steps.firstIndex(where: { $0.id == stepID }) else { return false }
        var replaced = steps[position]
        replaced.kind = kind
        guard replaced.isSuccess == steps[position].isSuccess, replaced.isChecklistRow == steps[position].isChecklistRow else { return false }
        if case .switches(let old) = steps[position].kind {
            for item in old.flatMap(\.switches) { switches[item.id] = nil }
        }
        steps[position] = replaced
        seedSwitches(kind)
        return true
    }

    @discardableResult
    public mutating func beginPreparing() -> Bool {
        guard phase == .ready else { return false }
        phase = .preparing
        return true
    }

    public mutating func finishPreparing() {
        if phase == .preparing { phase = .ready }
    }

    private var previousIndex: Int? {
        guard !isFinished else { return nil }
        return (0..<index).last { !steps[$0].isAutomatic && steps[$0].isChecklistRow }
    }

    public var canGoBack: Bool { phase != .working && previousIndex != nil }

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
        guard works, phase != .working, phase != .preparing, current.isAutomatic || isPrimaryEnabled else { return false }
        phase = .working
        return true
    }

    public mutating func finishWork() {
        guard phase == .working else { return }
        saved.formUnion(current.fields.map(\.id))
        for field in current.fields { values[field.id] = nil }
        index = min(index + 1, steps.count - 1)
        phase = .ready
    }

    public mutating func fail(_ status: SetupStatus) {
        guard phase == .working || phase == .preparing else { return }
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
