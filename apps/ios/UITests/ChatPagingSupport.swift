import XCTest

struct PagingManifest: Decodable {
    struct Profile: Decodable {
        let sessionId: String
        let visible: [String]
        let hidden: [String]
        let visibleCount: Int
        let firstVisibleMarker: String
        let newestVisibleMarker: String
        let rows: Int
    }

    let profiles: [String: Profile]

    static func load(path: String) throws -> PagingManifest {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return PagingManifest(profiles: try decoder.decode([String: Profile].self, from: data))
    }

    func profile(_ slug: String) throws -> Profile {
        try XCTUnwrap(profiles[slug], "the perf manifest has no profile \(slug)")
    }
}

enum PagingMarker {
    private static let visibleExpression = try! NSRegularExpression(pattern: "\\bM[0-9]{5}\\b")
    private static let hiddenExpression = try! NSRegularExpression(pattern: "\\bH[0-9]{5}\\b")

    static func visible(in text: String) -> [String] {
        matches(visibleExpression, in: text)
    }

    static func hidden(in text: String) -> [String] {
        matches(hiddenExpression, in: text)
    }

    static func ordinal(_ marker: String) -> Int {
        Int(marker.dropFirst()) ?? 0
    }

    static func format(ordinal: Int) -> String {
        String(format: "M%05d", ordinal)
    }

    private static func matches(_ expression: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}

struct BubbleReading {
    let identifier: String
    let label: String
    let frame: CGRect
    let markers: [String]

    var marker: String? { markers.first }
}

struct ChatReading {
    let bubbles: [BubbleReading]
    let hiddenMarkers: [String]
    let olderState: String?
    let olderFrame: CGRect?
    let pillLabel: String?
    let thinkingVisible: Bool
    let region: CGRect

    var onScreen: [BubbleReading] {
        bubbles.filter { $0.marker != nil && $0.frame.intersects(region) }
    }

    var allMarkers: [String] {
        bubbles.flatMap(\.markers)
    }

    var oldestLoadedMarker: String? {
        guard let olderFrame else { return nil }
        return bubbles
            .filter { $0.marker != nil && $0.frame.minY >= olderFrame.maxY - 1 }
            .min { $0.frame.minY < $1.frame.minY }?.marker
    }

    func minY(of marker: String) -> CGFloat? {
        bubbles.first { $0.markers.contains(marker) }?.frame.minY
    }

    func sameLayout(as other: ChatReading, tolerance: CGFloat = 0.5) -> Bool {
        let mine = onScreen, theirs = other.onScreen
        guard mine.count == theirs.count, (olderFrame == nil) == (other.olderFrame == nil) else { return false }
        return zip(mine, theirs).allSatisfy { $0.marker == $1.marker && abs($0.frame.minY - $1.frame.minY) <= tolerance }
    }

    var duplicatedMarkers: [String] {
        Dictionary(grouping: allMarkers, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
    }

    var bottomMostBubble: BubbleReading? {
        onScreen.max { $0.frame.minY < $1.frame.minY }
    }
}

struct PagingAnchor {
    let marker: String
    let y: CGFloat
}

struct AnchorSample {
    let seconds: TimeInterval
    let anchorY: CGFloat?
    let olderState: String?
    let olderPresent: Bool
    let oldestLoaded: String?
    let pillLabel: String?
}

struct PageUpOutcome {
    let landings: Int
    let gestures: Int
    let seen: Set<String>

    var oldestSeenMarker: String? {
        seen.map(PagingMarker.ordinal).min().map(PagingMarker.format(ordinal:))
    }
}

enum ReachOutcome: String {
    case found
    case pagedBeforeFound
    case notFound
}

@MainActor
private struct SnapshotScan {
    var bubbles: [BubbleReading] = []
    var hiddenMarkers: [String] = []
    var olderState: String?
    var olderFrame: CGRect?
    var pillLabel: String?
    var thinkingVisible = false
    var chatFrame: CGRect?
    var composerFrame: CGRect?

    private static let bubbleIdentifiers: Set<String> = ["userBubble", "assistantBubble"]
    private static let navigationInset: CGFloat = 110
    private static let composerClearance: CGFloat = 8
    private static let composerFallbackHeight: CGFloat = 130

    mutating func visit(_ node: any XCUIElementSnapshot) {
        hiddenMarkers += PagingMarker.hidden(in: node.label)
        if Self.bubbleIdentifiers.contains(node.identifier) {
            bubbles.append(BubbleReading(identifier: node.identifier, label: node.label, frame: node.frame, markers: PagingMarker.visible(in: node.label)))
        } else {
            note(node)
        }
        for child in node.children { visit(child) }
    }

    private mutating func note(_ node: any XCUIElementSnapshot) {
        switch node.identifier {
        case "olderHistoryRow":
            olderState = node.value as? String
            olderFrame = node.frame
        case "scrollToBottomButton": pillLabel = node.label
        case "thinkingLine": thinkingVisible = true
        case "chatScreen": chatFrame = node.frame
        case "composerField": composerFrame = node.frame
        default: break
        }
    }

    func reading() -> ChatReading {
        ChatReading(
            bubbles: bubbles, hiddenMarkers: hiddenMarkers, olderState: olderState, olderFrame: olderFrame,
            pillLabel: pillLabel, thinkingVisible: thinkingVisible, region: region)
    }

    private var region: CGRect {
        guard let chatFrame else { return .null }
        let top = chatFrame.minY + Self.navigationInset
        let bottom = (composerFrame?.minY ?? chatFrame.maxY - Self.composerFallbackHeight) - Self.composerClearance
        return CGRect(x: chatFrame.minX, y: top, width: chatFrame.width, height: max(bottom - top, 1))
    }
}

@MainActor
final class PagingDriver {
    let app: XCUIApplication
    private(set) var region: CGRect = .null

    private static let slowDragFraction: CGFloat = 0.65
    private static let dragStartFraction: CGFloat = 0.12

    init(app: XCUIApplication) {
        self.app = app
    }

    func read() throws -> ChatReading {
        let snapshot: any XCUIElementSnapshot
        do {
            snapshot = try app.snapshot()
        } catch {
            Thread.sleep(forTimeInterval: 0.3)
            snapshot = try app.snapshot()
        }
        var scan = SnapshotScan()
        scan.visit(snapshot)
        let reading = scan.reading()
        if !reading.region.isNull { region = reading.region }
        return reading
    }

    func waitForContent(timeout: TimeInterval = 60) throws -> ChatReading {
        let deadline = Date().addingTimeInterval(timeout)
        var reading = try read()
        while reading.onScreen.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            reading = try read()
        }
        XCTAssertFalse(reading.onScreen.isEmpty, "no marked message appeared within \(Int(timeout)) s")
        return reading
    }

    func settled(timeout: TimeInterval = 8) throws -> (reading: ChatReading, settled: Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = try read()
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            let current = try read()
            if current.sameLayout(as: previous) { return (current, true) }
            previous = current
        }
        return (previous, false)
    }

    func quiesce(timeout: TimeInterval = 30) throws -> ChatReading {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = try read()
        var stableReadings = 0
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            let current = try read()
            stableReadings = current.sameLayout(as: previous) && current.olderState != "loading" ? stableReadings + 1 : 0
            previous = current
            if stableReadings >= 4 { return current }
        }
        return previous
    }

    func dragOlder() {
        drag(from: Self.dragStartFraction, to: Self.dragStartFraction + Self.slowDragFraction)
    }

    func dragNewer() {
        drag(from: Self.dragStartFraction + Self.slowDragFraction, to: Self.dragStartFraction)
    }

    func flingOlder() {
        app.descendants(matching: .any)["chatScreen"].swipeDown(velocity: .fast)
    }

    func flingNewer() {
        app.descendants(matching: .any)["chatScreen"].swipeUp(velocity: .fast)
    }

    func anchor(in reading: ChatReading) -> PagingAnchor? {
        let region = reading.region
        let contained = reading.onScreen.filter { $0.frame.minY >= region.minY && $0.frame.maxY <= region.maxY }
        let pool = contained.isEmpty ? reading.onScreen : contained
        guard let pick = pool.min(by: { abs($0.frame.midY - region.midY) < abs($1.frame.midY - region.midY) }),
              let marker = pick.marker else { return nil }
        return PagingAnchor(marker: marker, y: pick.frame.minY)
    }

    func sample(_ anchor: PagingAnchor, since start: Date) throws -> AnchorSample {
        let reading = try read()
        return AnchorSample(
            seconds: Date().timeIntervalSince(start), anchorY: reading.minY(of: anchor.marker), olderState: reading.olderState,
            olderPresent: reading.olderFrame != nil, oldestLoaded: reading.oldestLoadedMarker, pillLabel: reading.pillLabel)
    }

    func observe(_ anchor: PagingAnchor, for duration: TimeInterval, interval: TimeInterval = 0.1) throws -> [AnchorSample] {
        var samples: [AnchorSample] = []
        let start = Date()
        repeat {
            samples.append(try sample(anchor, since: start))
            Thread.sleep(forTimeInterval: interval)
        } while Date().timeIntervalSince(start) < duration
        return samples
    }

    func pageUp(landings wanted: Int, budget: TimeInterval = 600, maxGestures: Int = 300) throws -> PageUpOutcome {
        var oldestLoaded: Set<String> = []
        var seen: Set<String> = []
        var gestures = 0
        let deadline = Date().addingTimeInterval(budget)
        while oldestLoaded.count < wanted + 1, gestures < maxGestures, Date() < deadline {
            gestures += 1
            if gestures.isMultiple(of: 3) { flingOlder() } else { dragOlder() }
            let reading = try settled().reading
            seen.formUnion(reading.allMarkers)
            if let marker = reading.oldestLoadedMarker { oldestLoaded.insert(marker) }
        }
        return PageUpOutcome(landings: max(0, oldestLoaded.count - 1), gestures: gestures, seen: seen)
    }

    func leaveTopBoundary() {
        dragNewer()
        dragNewer()
    }

    func reach(_ marker: String, maxDrags: Int) throws -> ReachOutcome {
        for _ in 0..<maxDrags {
            let reading = try settled().reading
            if reading.allMarkers.contains(marker) { return .found }
            if reading.olderState == "loading" { return .pagedBeforeFound }
            dragOlder()
        }
        return try settled().reading.allMarkers.contains(marker) ? .found : .notFound
    }

    private func drag(from startFraction: CGFloat, to endFraction: CGFloat) {
        guard !region.isNull else { return }
        let start = coordinate(atY: region.minY + region.height * startFraction)
        let end = coordinate(atY: region.minY + region.height * endFraction)
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.25)
    }

    private func coordinate(atY y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y / app.frame.height))
    }
}

enum PagingMeasurements {
    static let fileName = "paging-measurements.json"

    static func merge(_ values: [String: Any], test: String, directory: String?) {
        guard let directory else { return }
        let folder = URL(fileURLWithPath: directory)
        let url = folder.appendingPathComponent(fileName)
        let existing = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var merged = existing
        merged[test] = values
        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    static func points(_ value: CGFloat) -> Double {
        (Double(value) * 100).rounded() / 100
    }

    static func seconds(_ value: TimeInterval) -> Double {
        (value * 100).rounded() / 100
    }
}

extension AnchorSample {
    func drift(from anchor: PagingAnchor) -> CGFloat? {
        anchorY.map { abs($0 - anchor.y) }
    }
}

extension Array where Element == AnchorSample {
    func maxDrift(from anchor: PagingAnchor) -> CGFloat {
        compactMap { $0.drift(from: anchor) }.max() ?? 0
    }

    func lostAnchorCount() -> Int {
        filter { $0.anchorY == nil }.count
    }
}
