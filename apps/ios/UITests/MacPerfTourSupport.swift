#if os(macOS)
import AppKit
import XCTest

struct TourSkip: Error {
    let reason: String
}

struct TourPhase: Encodable {
    let surface: String
    let startedAt: Double
    let endedAt: Double
    let skipped: String?
}

enum ScrollDirection {
    case older
    case newer
}

@MainActor
class MacPerfTourCase: BotProfileTestCase {
    var app: XCUIApplication!
    var phaseLines = Data()
    var kanbanSeeded = false
    var seed = ""
    var measured: (start: Double, end: Double)?
    var olderSign: CGFloat = 1
    var holdsSettingsOpen = false

    var window: XCUIElement { app.windows.firstMatch }

    func runPhase(_ surface: String, _ body: () throws -> Void) {
        measured = nil
        var skipped: String?
        do { try body() } catch { skipped = (error as? TourSkip)?.reason ?? String(describing: error) }
        let now = Date().timeIntervalSince1970
        let span = measured ?? (now, now)
        if measured == nil, skipped == nil { skipped = "the phase measured nothing" }
        if skipped != nil {
            shot(app, "skipped-\(surface)")
            screenShot("skipped-screen-\(surface)")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "hierarchy-\(surface)"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        record(TourPhase(surface: surface, startedAt: span.start, endedAt: span.end, skipped: skipped))
        recover()
        idle(1)
    }

    func record(_ phase: TourPhase) {
        guard let data = try? JSONEncoder().encode(phase) else {
            XCTFail("phase \(phase.surface) did not encode")
            return
        }
        phaseLines.append(data)
        phaseLines.append(Data("\n".utf8))
    }

    func attachPhases() {
        let attachment = XCTAttachment(data: phaseLines, uniformTypeIdentifier: "public.json")
        attachment.name = "perf-phases"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func measuring(_ body: () throws -> Void) throws {
        let start = Date().timeIntervalSince1970
        defer { measured = (start, Date().timeIntervalSince1970) }
        try body()
    }

    func idle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func poll(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.4)
        } while Date() < deadline
        return false
    }

    func need(_ identifier: String, _ timeout: TimeInterval = 10) throws -> XCUIElement {
        let found = el(identifier)
        guard found.waitForExistence(timeout: timeout) else { throw TourSkip(reason: "\(identifier) did not appear") }
        return found
    }

    func needButton(_ identifier: String, _ timeout: TimeInterval = 10) throws -> XCUIElement {
        let found = button(identifier)
        guard found.waitForExistence(timeout: timeout) else { throw TourSkip(reason: "button \(identifier) did not appear") }
        return found
    }

    func el(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    func tap(_ target: XCUIElement) -> Bool {
        guard target.exists else { return false }
        if target.isHittable {
            target.hit()
        } else {
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        return true
    }

    func button(_ identifier: String) -> XCUIElement {
        app.buttons.matching(identifier: identifier).firstMatch
    }

    func escape() {
        app.typeKey(.escape, modifierFlags: [])
    }

    func ensureExpandedSidebar() {
        guard el("sidebarRail").exists else { return }
        app.typeKey("b", modifierFlags: .command)
        waitFor(el("sidebarExpanded"), timeout: 10, "expanded sidebar")
    }

    func botRows() -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-")).allElementsBoundByIndex
            .filter { $0.isHittable }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    func slug(_ row: XCUIElement) -> String {
        String(row.identifier.dropFirst("botRow-".count))
    }

    func recover() {
        let overlays: [(String, () -> Void)] = [
            ("settingsSheet", { self.tap(self.button("settingsClose")) }),
            ("createBotSheet", { self.tap(self.button("createBotCancel")) }),
            ("renameBotSheet", { self.tap(self.button("renameBotCancel")) }),
            ("shortcutsSheet", { self.tap(self.button("shortcutsClose")) }),
            ("ownerSetup", { self.tap(self.el("stepFlowClose")) }),
            ("connectApps", { self.tap(self.button("connectApps-close")) }),
            ("createRoomSheet", { self.tap(self.button("createRoomSheet-close")) }),
            ("roomDetailsSheet", { self.tap(self.button("roomDetailsSheet-close")) }),
            ("newRoutineSheet", { self.tap(self.button("newRoutineSheet-close")) }),
            ("searchScreen", escape),
            ("macDialog", escape),
            ("accountMenu", escape),
            ("messageContextMenu", escape),
            ("kanbanBody", escape),
            ("kanbanBoard", escape),
        ]
        for _ in 0..<6 {
            guard let open = overlays.first(where: { !(holdsSettingsOpen && $0.0 == "settingsSheet") && el($0.0).exists }) else { return }
            open.1()
            idle(0.6)
        }
    }

    func point(_ x: CGFloat, _ y: CGFloat, origin: CGPoint) -> XCUICoordinate {
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - origin.x, dy: y - origin.y))
    }

    func hoverSweep(_ frames: [CGRect], stepsBetween: Int = 3) {
        let origin = window.frame.origin
        var previous: CGPoint?
        for frame in frames {
            let target = CGPoint(x: frame.midX, y: frame.midY)
            if let from = previous {
                for step in 1...stepsBetween {
                    let fraction = CGFloat(step) / CGFloat(stepsBetween + 1)
                    point(from.x + (target.x - from.x) * fraction, from.y + (target.y - from.y) * fraction, origin: origin).hover()
                }
            }
            point(target.x, target.y, origin: origin).hover()
            previous = target
        }
    }

    func scroll(_ target: XCUIElement, by delta: CGFloat, times: Int) {
        let frame = target.frame
        let spot = point(frame.midX, frame.midY, origin: window.frame.origin)
        for _ in 0..<times { spot.scroll(byDeltaX: 0, deltaY: delta) }
    }

    func chatScroll(_ direction: ScrollDirection, by delta: CGFloat = 480, times: Int) {
        scroll(el("chatScreen"), by: direction == .older ? delta * olderSign : -delta * olderSign, times: times)
    }

    func calibrateScrollDirection() {
        let chat = el("chatScreen")
        let jump = el("scrollToBottomButton")
        for sign: CGFloat in [1, -1] {
            scroll(chat, by: 400 * sign, times: 3)
            idle(0.5)
            if jump.exists {
                olderSign = sign
                tap(jump)
                idle(1)
                return
            }
        }
    }

    func openChat(slug: String) throws {
        let row = button("botRow-\(slug)")
        guard row.waitForExistence(timeout: 15) else { throw TourSkip(reason: "no sidebar row for \(slug)") }
        tap(row)
        _ = try need("chatScreen", 20)
        _ = try need("composerField", 20)
    }

    func setInspector(open wanted: Bool) {
        guard el("botProfileScreen").exists != wanted else { return }
        app.typeKey("i", modifierFlags: [.command, .shift])
        idle(0.8)
    }

    func currentChatTitle() -> String {
        let title = el("chatTitle")
        return title.exists ? title.label : ""
    }

    func firstTwoSlugs() throws -> (String, String) {
        let slugs = botRows().map(slug)
        if slugs.contains("bot-alpha"), slugs.contains("bot-beta") { return ("bot-alpha", "bot-beta") }
        guard slugs.count >= 2 else { throw TourSkip(reason: "the roster has fewer than two reachable bots") }
        return (slugs[0], slugs[1])
    }
}
#endif
