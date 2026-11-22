#if os(macOS)
import XCTest

@MainActor
final class MacPerfTourTests: MacPerfTourCase {
    private static let streamTrigger = "STREAM-LONG-MARKDOWN"
    private static let streamTimeout: TimeInterval = 80
    private static let streamMinimum: TimeInterval = 30

    func testTourEverySurface() throws {
        let environment = ProcessInfo.processInfo.environment
        let appDirectory = try XCTUnwrap(environment["HERMES_UITEST_PERF_APP_DIR"], "HERMES_UITEST_PERF_APP_DIR not set")
        seed = environment["HERMES_UITEST_SEED"] ?? ""
        kanbanSeeded = environment["HERMES_UITEST_KANBAN_SEEDED"] == "1"
        addTeardownBlock { @MainActor [self] in attachPhases() }

        app = signedInApp(extraArguments: ["-hermes-test-oauth-client"], environment: ["PAL_PERF": "1", "PAL_PERF_DIR": appDirectory])
        app.activate()
        ensureExpandedSidebar()
        idle(1)

        let tour: [(String, () throws -> Void)] = [
            ("sidebar-expanded", sidebarExpanded),
            ("roster-select", rosterSelect),
            ("chat-open-cold", chatOpenCold),
            ("chat-open-warm", chatOpenWarm),
            ("chat-history-scroll", chatHistoryScroll),
            ("composer-typing", composerTyping),
            ("chat-streaming-scroll", chatStreamingScroll),
            ("message-menu", messageMenu),
            ("inspector-activity", inspectorActivity),
            ("inspector-library", inspectorLibrary),
            ("routine-sheet", routineSheet),
            ("computer-view", computerView),
            ("search-palette", searchPalette),
            ("create-bot-sheet", createBotSheet),
            ("rooms-create-sheet", roomsCreateSheet),
            ("room-view", roomView),
            ("connect-apps", connectApps),
            ("connect-apps-setup", connectAppsSetup),
            ("kanban-board", kanbanBoard),
            ("kanban-card-detail", kanbanCardDetail),
            ("settings-open", settingsOpen),
            ("settings-general", { try self.settingsPane("general") }),
            ("appearance-switch", appearanceSwitch),
            ("settings-computer", { try self.settingsPane("computer") }),
            ("settings-permissions", { try self.settingsPane("permissions") }),
            ("settings-vault", settingsVault),
            ("settings-model-providers", settingsProviders),
            ("settings-usage", { try self.settingsPane("usage") }),
            ("settings-updates", { try self.settingsPane("updates") }),
            ("modals-dialogs", modalsDialogs),
            ("sidebar-rail", sidebarRail),
            ("sidebar-drag", sidebarDrag),
            ("window-resize", windowResize),
        ]
        let selected = Set((environment["HERMES_UITEST_TOUR_PHASES"] ?? "").split(separator: ",").map(String.init))
        for (surface, body) in tour where selected.isEmpty || selected.contains(surface) { runPhase(surface, body) }

        idle(3)
        app.typeKey("q", modifierFlags: .command)
        _ = app.wait(for: .notRunning, timeout: 15)
    }

    private func sidebarExpanded() throws {
        _ = try need("sidebarExpanded")
        let rows = botRows()
        let frames = rows.map(\.frame)
        let list = el("rosterScreen")
        try measuring {
            idle(2)
            scroll(list, by: -300, times: 6)
            scroll(list, by: 300, times: 6)
            hoverSweep(frames)
        }
    }

    private func rosterSelect() throws {
        let rows = Array(botRows().prefix(12))
        guard rows.count >= 5 else {
            throw TourSkip(reason: "the \(seed.isEmpty ? "default" : seed) seed shows \(rows.count) bots; run with --seed parity for the 20-bot roster")
        }
        try measuring {
            for row in rows {
                tap(row)
                idle(1.2)
            }
            app.typeKey("1", modifierFlags: .command)
            idle(0.8)
            app.typeKey("2", modifierFlags: .command)
            idle(0.8)
            app.typeKey(.downArrow, modifierFlags: .option)
            idle(0.8)
        }
    }

    private func chatOpenCold() throws {
        let (first, second) = try firstTwoSlugs()
        let target = currentChatTitle().localizedCaseInsensitiveContains(second) ? first : second
        let row = try needButton("botRow-\(target)", 15)
        try measuring {
            tap(row)
            _ = poll(20) { el("chatScreen").exists && el("composerField").exists }
            _ = poll(20) { self.app.descendants(matching: .any)["assistantBubble"].exists }
            idle(1.5)
        }
    }

    private func chatOpenWarm() throws {
        let (first, second) = try firstTwoSlugs()
        let current = currentChatTitle().localizedCaseInsensitiveContains(second) ? second : first
        let other = current == first ? second : first
        try openChat(slug: other)
        idle(1)
        let back = try needButton("botRow-\(current)", 15)
        try measuring {
            tap(back)
            _ = poll(20) { self.app.descendants(matching: .any)["assistantBubble"].exists }
            idle(1.5)
        }
    }

    private func chatHistoryScroll() throws {
        guard seed == "perf" else { throw TourSkip(reason: "the long Bot Chats need --seed perf") }
        guard button("botRow-bot-beta").waitForExistence(timeout: 10) else { throw TourSkip(reason: "bot-beta is not in the roster") }
        try openChat(slug: "bot-beta")
        idle(1.5)
        calibrateScrollDirection()
        try measuring {
            idle(2)
            chatScroll(.older, times: 40)
            idle(1)
            chatScroll(.newer, times: 40)
            if el("scrollToBottomButton").exists { tap(el("scrollToBottomButton")) }
            idle(1)
        }
    }

    private func composerTyping() throws {
        let field = try need("composerField", 15)
        tap(field)
        try measuring {
            field.typeText("Drafting a longer note to see how the composer behaves while the text keeps growing ")
            for _ in 0..<4 {
                app.typeKey(.return, modifierFlags: .shift)
                field.typeText("another line of the draft")
            }
            idle(1)
            app.typeKey("a", modifierFlags: .command)
            app.typeKey(.delete, modifierFlags: [])
            idle(0.5)
        }
    }

    private func chatStreamingScroll() throws {
        let field = try need("composerField", 15)
        tap(field)
        field.typeText(Self.streamTrigger)
        let streaming = el("assistantBubble-streaming")
        try measuring {
            app.typeKey(.return, modifierFlags: [])
            guard poll(15, { streaming.exists }) else { throw TourSkip(reason: "the stub reply never started streaming") }
            let floor = Date().addingTimeInterval(Self.streamMinimum)
            let deadline = Date().addingTimeInterval(Self.streamTimeout)
            var direction = ScrollDirection.older
            while Date() < floor || (streaming.exists && Date() < deadline) {
                chatScroll(direction, by: 360, times: 6)
                direction = direction == .older ? .newer : .older
            }
            chatScroll(.newer, by: 900, times: 6)
            idle(1.5)
        }
    }

    private func messageMenu() throws {
        let field = try need("composerField", 15)
        let probe = "short reply for the menu"
        let replies = app.descendants(matching: .any).matching(identifier: "assistantBubble")
        tap(field)
        field.typeText(probe)
        app.typeKey(.return, modifierFlags: [])
        let answer = replies.matching(NSPredicate(format: "label BEGINSWITH %@", "stub-")).firstMatch
        let answered = poll(40) { answer.exists && !el("assistantBubble-streaming").exists }
        guard answered else { throw TourSkip(reason: "the short reply never completed") }
        idle(1)
        let reply = answer
        app.activate()
        idle(1)
        try measuring {
            let spots = [CGVector(dx: 0.9, dy: 0.9), CGVector(dx: 0.5, dy: 0.5), CGVector(dx: 0.2, dy: 0.3), CGVector(dx: 0.8, dy: 0.2)]
            let shown = spots.contains { spot in
                reply.coordinate(withNormalizedOffset: spot).hover()
                idle(0.6)
                return poll(1.5) { el("messageMore").exists }
            }
            if shown, tap(el("messageMore")) {
                idle(1.2)
                escape()
                idle(0.6)
            }
            reply.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
            guard poll(4, { el("contextCopy").exists }) else { throw TourSkip(reason: "the message context menu never appeared") }
            idle(1.2)
            escape()
            idle(0.6)
        }
    }
}
#endif
