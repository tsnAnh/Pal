import XCTest

@MainActor
final class ChatSegmentIdentityE2ETests: E2ETestCase {
    private static let commentary = "Pal took job 145 but needs to check the queue first."
    private static let narratedFinal = "hermes-stub-narrate"
    private static let clarifyFinal = "Got it, chocolate"
    private static let settleSeconds: TimeInterval = 8
    private static let turnBudget: TimeInterval = 120

    func test1NarratedToolTurnPaintsEachReplyOnceInPlace() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-alpha")
        let prompt = "NARRATE once " + UUID().uuidString.prefix(6)
        send(app, prompt)
        let watch = TurnWatch(app: app, prompt: prompt, replies: [Self.commentary, Self.narratedFinal])
        try watch.sample(until: { $0.contains(Self.narratedFinal) && !$0.thinking }, budget: Self.turnBudget)
        shot(app, "narrate-1-complete")
        try watch.sample(for: Self.settleSeconds)
        shot(app, "narrate-2-settled")
        watch.assertEachReplyOnceInPlace(ordered: [Self.commentary, Self.narratedFinal])

        app.terminate()
        let reopened = launch()
        signInIfNeeded(reopened)
        openBot(reopened, "bot-alpha")
        let after = TurnWatch(app: reopened, prompt: prompt, replies: [Self.commentary, Self.narratedFinal])
        try after.sample(until: { $0.contains(Self.narratedFinal) }, budget: 30)
        try after.sample(for: 3)
        shot(reopened, "narrate-3-reopened")
        after.assertEachReplyOnceInPlace(ordered: [Self.commentary, Self.narratedFinal])
    }

    func test2NarratedClarifyTurnPaintsEachReplyOnceInPlace() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        let prompt = "NARRASK pick " + UUID().uuidString.prefix(6)
        send(app, prompt)
        let replies = [Self.commentary, Self.clarifyFinal]
        let watch = TurnWatch(app: app, prompt: prompt, replies: replies)
        try watch.sample(until: { $0.hasClarifyCard }, budget: Self.turnBudget)
        try watch.sample(for: 2)
        shot(app, "narrask-1-question")
        let choice = app.buttons["clarifyChoice-1"]
        waitFor(choice, timeout: 10, "clarify choice")
        choice.tap()
        try watch.sample(until: { $0.contains(Self.clarifyFinal) && !$0.thinking }, budget: Self.turnBudget)
        shot(app, "narrask-2-complete")
        try watch.sample(for: Self.settleSeconds)
        shot(app, "narrask-3-settled")
        watch.assertEachReplyOnceInPlace(ordered: [Self.commentary, TurnWatch.answeredCard, Self.clarifyFinal])

        app.terminate()
        let reopened = launch()
        signInIfNeeded(reopened)
        openBot(reopened, "bot-beta")
        let after = TurnWatch(app: reopened, prompt: prompt, replies: replies)
        try after.sample(until: { $0.contains(Self.clarifyFinal) }, budget: 30)
        try after.sample(for: 3)
        shot(reopened, "narrask-4-reopened")
        after.assertEachReplyOnceInPlace(ordered: [Self.commentary, TurnWatch.answeredCard, Self.clarifyFinal])
    }
}

@MainActor
final class TurnWatch {
    static let answeredCard = "answered-card"

    struct Row: Equatable {
        let identity: String
        let minY: CGFloat
    }

    struct Frame {
        let seconds: TimeInterval
        let rows: [Row]
        let thinking: Bool
        let hasClarifyCard: Bool

        func contains(_ reply: String) -> Bool { rows.contains { $0.identity == reply } }
        func count(_ identity: String) -> Int { rows.count { $0.identity == identity } }
        var order: [String] { rows.map(\.identity) }
    }

    private let app: XCUIApplication
    private let prompt: String
    private let replies: [String]
    private let started = Date()
    private(set) var frames: [Frame] = []

    init(app: XCUIApplication, prompt: String, replies: [String]) {
        self.app = app
        self.prompt = prompt
        self.replies = replies
    }

    func sample(until done: (Frame) -> Bool, budget: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            let frame = try read()
            frames.append(frame)
            if done(frame) { return }
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTFail("turn for \(prompt) did not reach its goal; last order \(frames.last?.order ?? [])")
    }

    func sample(for duration: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            frames.append(try read())
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
    }

    func assertEachReplyOnceInPlace(ordered expected: [String], file: StaticString = #filePath, line: UInt = #line) {
        let identities = Set(frames.flatMap(\.order))
        for identity in identities {
            let worst = frames.map { $0.count(identity) }.max() ?? 0
            let at = frames.first { $0.count(identity) > 1 }
            XCTAssertLessThanOrEqual(worst, 1, "\(identity) painted \(worst) times at \(String(format: "%.1f", at?.seconds ?? 0)) s: \(at?.order ?? [])", file: file, line: line)
        }
        guard let last = frames.last else { return XCTFail("no frames sampled", file: file, line: line) }
        XCTAssertEqual(last.order, expected, "rows below the prompt once settled", file: file, line: line)
        var seenBefore: [String: Set<String>] = [:]
        for frame in frames {
            let order = frame.order
            for (index, identity) in order.enumerated() {
                let above = Set(order[..<index])
                let below = Set(order[(index + 1)...])
                if let earlier = seenBefore[identity] {
                    let flipped = earlier.intersection(below)
                    XCTAssertTrue(flipped.isEmpty, "\(identity) moved above \(flipped.sorted()) at \(String(format: "%.1f", frame.seconds)) s: \(order)", file: file, line: line)
                }
                seenBefore[identity, default: []].formUnion(above)
            }
        }
    }

    private func read() throws -> Frame {
        let snapshot: any XCUIElementSnapshot
        do {
            snapshot = try app.snapshot()
        } catch {
            Thread.sleep(forTimeInterval: 0.3)
            snapshot = try app.snapshot()
        }
        var scan = Scan()
        scan.visit(snapshot)
        let promptTop = scan.nodes.first { $0.identifier == "userBubble" && $0.label.contains(prompt) }?.frame.minY
        let rows = scan.nodes
            .filter { node in promptTop.map { node.frame.minY > $0 } ?? false }
            .compactMap { node -> Row? in identity(of: node).map { Row(identity: $0, minY: node.frame.minY) } }
            .sorted { $0.minY < $1.minY }
        return Frame(seconds: Date().timeIntervalSince(started), rows: rows, thinking: scan.thinking, hasClarifyCard: scan.clarifyCard)
    }

    private func identity(of node: Scan.Node) -> String? {
        switch node.identifier {
        case "clarifyAnswered": Self.answeredCard
        case "assistantBubble": replies.first { node.label.contains($0) } ?? "assistant:" + node.label.prefix(40)
        case "userBubble": "user:" + node.label.prefix(40)
        default: nil
        }
    }

    private struct Scan {
        struct Node {
            let identifier: String
            let label: String
            let frame: CGRect
        }

        static let rowIdentifiers: Set<String> = ["userBubble", "assistantBubble", "clarifyAnswered"]
        var nodes: [Node] = []
        var thinking = false
        var clarifyCard = false

        mutating func visit(_ node: any XCUIElementSnapshot) {
            if Self.rowIdentifiers.contains(node.identifier) {
                nodes.append(Node(identifier: node.identifier, label: node.label, frame: node.frame))
            } else if node.identifier == "assistantBubble-streaming" || node.identifier == "thinkingLine" {
                thinking = true
            } else if node.identifier == "clarifyCard" {
                clarifyCard = true
            }
            for child in node.children { visit(child) }
        }
    }
}
