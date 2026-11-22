#if os(macOS)
import XCTest

extension MacPerfTourTests {
    func inspectorActivity() throws {
        setInspector(open: true)
        _ = try need("botProfileScreen", 15)
        idle(1)
        let inspector = el("botProfileScreen")
        try measuring {
            idle(2)
            scroll(inspector, by: -300, times: 5)
            scroll(inspector, by: 300, times: 5)
            let rows = inspector.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "routineToggle-")).allElementsBoundByIndex
            hoverSweep(rows.map(\.frame))
        }
    }

    func inspectorLibrary() throws {
        setInspector(open: true)
        let tab = try need("inspectorTab-library", 10)
        try measuring {
            tap(tab)
            _ = poll(20) { el("libraryScreen").exists }
            idle(2)
            let library = el("libraryScreen")
            for filter in ["media", "files", "all"] {
                let chip = el("libraryFilter-\(filter)")
                if chip.exists { tap(chip) }
                idle(0.8)
            }
            scroll(library, by: -400, times: 10)
            scroll(library, by: 400, times: 10)
        }
        setInspector(open: false)
    }

    func routineSheet() throws {
        setInspector(open: true)
        _ = try need("botProfileScreen", 15)
        let more = try need("profileMoreButton", 10)
        tap(more)
        let item = app.menuItems["New Routine…"]
        guard item.waitForExistence(timeout: 5) else { throw TourSkip(reason: "the New Routine menu item did not appear") }
        try measuring {
            tap(item)
            _ = try need("newRoutineSheet", 10)
            idle(1.5)
            let prompt = el("newRoutinePrompt")
            if prompt.exists {
                tap(prompt)
                prompt.typeText("Every weekday morning summarise the open pull requests")
            }
            idle(1)
            tap(button("newRoutineSheet-close"))
            idle(0.8)
        }
    }

    func computerView() throws {
        setInspector(open: true)
        _ = try need("botProfileScreen", 15)
        let row = try need("profileComputerRow", 10)
        let leaveSlug = try firstTwoSlugs().0
        let leave = try needButton("botRow-\(leaveSlug)", 10)
        tap(row)
        _ = try need("computerScreen", 20)
        _ = poll(30) { el("computerStatus").label == "watching" }
        try measuring {
            idle(4)
            hoverSweep([el("computerScreen").frame])
            idle(2)
        }
        tap(leave)
        idle(1)
    }

    func searchPalette() throws {
        app.typeKey("k", modifierFlags: .command)
        let field = try need("searchField", 10)
        try measuring {
            idle(1)
            field.typeText("bot")
            idle(1)
            for _ in 0..<5 {
                app.typeKey(.downArrow, modifierFlags: [])
                idle(0.2)
            }
            for _ in 0..<5 {
                app.typeKey(.upArrow, modifierFlags: [])
                idle(0.2)
            }
            escape()
            idle(0.8)
        }
    }

    func createBotSheet() throws {
        app.typeKey("n", modifierFlags: .command)
        _ = try need("createBotSheet", 15)
        _ = try need("createBotPreview", 10)
        let shapes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botShape-")).allElementsBoundByIndex
        let swatches = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botSwatch-")).allElementsBoundByIndex
        let name = el("botNameField")
        try measuring {
            idle(2)
            for shape in shapes { tap(shape); idle(0.3) }
            for swatch in swatches { tap(swatch); idle(0.25) }
            tap(name)
            name.typeText("Pal Scout")
            idle(1)
            tap(button("createBotCancel"))
            idle(0.8)
        }
    }

    func roomsCreateSheet() throws {
        let open = button("createRoomButton")
        guard open.waitForExistence(timeout: 30) else {
            throw TourSkip(reason: "New Group Chat is unavailable: no room driver, or fewer than two seatable bots")
        }
        tap(open)
        _ = try need("createRoomSheet", 15)
        let field = app.textFields["roomNameField"]
        let picks = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "roomPick-")).allElementsBoundByIndex
        guard picks.count >= 2 else { throw TourSkip(reason: "the create sheet lists fewer than two bots") }
        let create = try needButton("roomCreateButton", 10)
        try measuring {
            idle(1.5)
            tap(field)
            field.typeText("Perf Tour Crew")
            for pick in picks.prefix(3) { tap(pick); idle(0.4) }
            tap(create)
            _ = poll(30) { !el("createRoomSheet").exists }
            idle(1.5)
        }
    }

    func roomView() throws {
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "roomRow-"))
        guard rows.firstMatch.waitForExistence(timeout: 20) else { throw TourSkip(reason: "no room exists to open") }
        let row = rows.firstMatch
        try measuring {
            tap(row)
            _ = try need("roomScreen", 20)
            idle(2)
            scroll(el("roomScreen"), by: -300, times: 6)
            scroll(el("roomScreen"), by: 300, times: 6)
            let title = el("roomTitle")
            if title.exists {
                tap(title)
                _ = poll(8) { el("roomDetailsSheet").exists }
                idle(1.5)
                tap(button("roomDetailsSheet-close"))
                idle(0.8)
            }
        }
    }

    func connectApps() throws {
        app.typeKey("m", modifierFlags: [.command, .shift])
        _ = try need("connectApps", 20)
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "connectApp-"))
        guard rows.firstMatch.waitForExistence(timeout: 40) else { throw TourSkip(reason: "the connector catalog never loaded") }
        idle(1)
        let list = el("connectApps")
        let search = el("connectAppsSearch")
        let frames = rows.allElementsBoundByIndex.prefix(10).map(\.frame)
        try measuring {
            idle(2)
            scroll(list, by: -500, times: 8)
            scroll(list, by: 500, times: 8)
            hoverSweep(Array(frames))
            for chip in ["device", "all"] {
                let button = button("connectAppsChip-\(chip)")
                if button.exists { tap(button); idle(0.8) }
            }
            if search.exists {
                tap(search)
                search.typeText("goo")
                idle(1)
            }
        }
        tap(button("connectApps-close"))
        waitGone(el("connectApps"), timeout: 10, "connect apps closes")
    }

    func connectAppsSetup() throws {
        app.typeKey("m", modifierFlags: [.command, .shift])
        _ = try need("connectApps", 20)
        let search = try need("connectAppsSearch", 15)
        tap(search)
        search.typeText("Google Workspace")
        let action = try needButton("connectApp-connector:google-workspace-action", 30)
        try measuring {
            tap(action)
            _ = try need("ownerSetup", 20)
            _ = try need("stepFlowPrimary", 20)
            idle(2)
            tap(el("stepFlowPrimary"))
            idle(2)
            tap(el("stepFlowClose"))
            waitGone(el("ownerSetup"), timeout: 10, "setup window closes")
        }
        tap(button("connectApps-close"))
    }

    func openKanbanBoard() throws {
        if !kanbanSeeded { try control("kanban-seed") }
        let entry = try needButton("kanbanButton", 20)
        tap(entry)
        _ = try need("kanbanBoard", 20)
        let picker = try need("kanbanBoardPicker", 20)
        tap(picker)
        let ops = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "kanbanBoard-ops", "Ops")).firstMatch
        if ops.waitForExistence(timeout: 10) { tap(ops) }
    }

    func kanbanBoard() throws {
        try openKanbanBoard()
        idle(1)
        let board = el("kanbanBoard")
        try measuring {
            idle(2)
            scroll(board, by: -400, times: 6)
            scroll(board, by: 400, times: 6)
            let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "kanbanCard-")).allElementsBoundByIndex
            hoverSweep(cards.map(\.frame))
            let search = el("kanbanSearch")
            if search.exists {
                tap(search)
                search.typeText("notes")
                idle(1)
                escape()
                idle(0.5)
            }
        }
    }

    func kanbanCardDetail() throws {
        if !el("kanbanBoard").exists { try openKanbanBoard() }
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "kanbanCard-")).firstMatch
        guard card.waitForExistence(timeout: 30) else { throw TourSkip(reason: "the seeded board shows no cards") }
        try measuring {
            tap(card)
            _ = try need("kanbanBody", 20)
            idle(2)
            scroll(el("kanbanBody"), by: -300, times: 4)
            scroll(el("kanbanBody"), by: 300, times: 4)
            escape()
            idle(0.8)
            escape()
            idle(0.8)
        }
    }

}
#endif
