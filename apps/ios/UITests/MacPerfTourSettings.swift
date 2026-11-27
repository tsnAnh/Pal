#if os(macOS)
import PalDesign
import XCTest

extension MacPerfTourTests {
    func settingsOpen() throws {
        holdsSettingsOpen = true
        try measuring {
            app.typeKey(",", modifierFlags: .command)
            _ = try need("settingsSheet", 15)
            idle(2)
        }
    }

    func settingsPane(_ pane: String) throws {
        let row = try paneRow(pane)
        try measuring {
            tap(row)
            _ = try need("macSettingsPage-\(pane)", 10)
            idle(2)
            let page = el("macSettingsPage-\(pane)")
            scroll(page, by: -400, times: 5)
            scroll(page, by: 400, times: 5)
        }
    }

    func paneRow(_ pane: String) throws -> XCUIElement {
        if !el("settingsSheet").exists {
            app.typeKey(",", modifierFlags: .command)
            _ = try need("settingsSheet", 15)
        }
        return try needButton("macSettingsSection-\(pane)", 10)
    }

    func appearanceSwitch() throws {
        let row = try paneRow("general")
        tap(row)
        _ = try need("macSettingsPage-general", 10)
        let menu = try need("macThemeMenu", 10)
        try measuring {
            for mode in [AppearanceMode.light, .black, .dark] {
                tap(menu)
                let item = app.menuItems[mode.title]
                guard item.waitForExistence(timeout: 5) else { throw TourSkip(reason: "the \(mode.title) theme item did not appear") }
                tap(item)
                idle(2)
            }
        }
    }

    func settingsVault() throws {
        let row = try paneRow("vault")
        try measuring {
            tap(row)
            _ = try need("macSettingsPage-vault", 10)
            idle(2)
            for tab in ["logins", "payments", "all"] {
                let button = button("macVaultTab-\(tab)")
                if button.exists { tap(button); idle(0.8) }
            }
            let add = button("vaultAddButton")
            if add.exists {
                tap(add)
                _ = poll(8) { el("vaultAddSheet").exists }
                idle(1.5)
                escape()
                idle(0.8)
            }
        }
    }

    func settingsProviders() throws {
        let row = try paneRow("providers")
        try measuring {
            tap(row)
            _ = try need("macSettingsPage-providers", 10)
            _ = poll(30) { el("modelProviders-connected").exists }
            idle(2)
            let page = el("macSettingsPage-providers")
            scroll(page, by: -500, times: 6)
            scroll(page, by: 500, times: 6)
            let search = el("providersSearchField")
            if search.exists {
                tap(search)
                search.typeText("open")
                idle(1)
            }
        }
    }

    func modalsDialogs() throws {
        holdsSettingsOpen = false
        if el("settingsSheet").exists {
            tap(button("settingsClose"))
            waitGone(el("settingsSheet"), timeout: 10, "settings closes")
        }
        let slug = try firstTwoSlugs().1
        let row = try needButton("botRow-\(slug)", 15)
        try measuring {
            app.typeKey("/", modifierFlags: .command)
            _ = try need("shortcutsSheet", 10)
            idle(1.5)
            tap(button("shortcutsClose"))
            waitGone(el("shortcutsSheet"), timeout: 10, "shortcuts close")

            tap(button("userAvatarButton"))
            _ = try need("accountMenu", 10)
            idle(1.2)
            escape()
            idle(0.6)

            row.rightClick()
            let rename = app.menuItems["renameBotAction"]
            if rename.waitForExistence(timeout: 5) {
                tap(rename)
                _ = poll(8) { el("renameBotSheet").exists }
                idle(1.5)
                tap(button("renameBotCancel"))
                idle(0.8)
            } else {
                escape()
            }

            app.typeKey(",", modifierFlags: .command)
            _ = try need("settingsSheet", 15)
            tap(button("macSettingsSection-general"))
            _ = try need("macSettingsPage-general", 10)
            let signOut = try needButton("settingsSignOutRow", 10)
            tap(signOut)
            _ = poll(8) { el("macDialog").exists }
            idle(1.5)
            let cancel = button("Cancel")
            if cancel.exists { tap(cancel) } else { escape() }
            idle(0.8)
            tap(button("settingsClose"))
            idle(0.8)
        }
    }

    func sidebarRail() throws {
        let rows = botRows()
        guard !rows.isEmpty else { throw TourSkip(reason: "no bot rows to compare against the rail") }
        app.typeKey("b", modifierFlags: .command)
        _ = try need("sidebarRail", 10)
        idle(1)
        let railRows = botRows().prefix(8)
        let frames = railRows.map(\.frame)
        try measuring {
            idle(2)
            hoverSweep(frames, stepsBetween: 2)
            for row in railRows.prefix(4) {
                tap(row)
                idle(1)
            }
        }
        app.typeKey("b", modifierFlags: .command)
        _ = try need("sidebarExpanded", 10)
    }

    func sidebarDrag() throws {
        let initial = try need("sidebarExpanded", 10).frame
        let chatOrigin = try need("chatScreen", 10).frame.minX
        let origin = window.frame.origin
        let range = MacLayoutMetrics.sidebarWidthRange
        let travel = CGFloat(range.upperBound - range.lowerBound)
        func drag(from start: CGFloat, to end: CGFloat) {
            point(start, initial.midY, origin: origin)
                .click(forDuration: 0.1, thenDragTo: point(end, initial.midY, origin: origin), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        try measuring {
            for sweep in 0..<3 {
                let edge = initial.maxX - 2 + el("chatScreen").frame.minX - chatOrigin
                drag(from: edge, to: edge + travel)
                let widening = el("chatScreen").frame.minX - chatOrigin
                if sweep == 0, abs(widening) < 4 { throw TourSkip(reason: "the sidebar divider did not respond to the drag") }
                drag(from: initial.maxX - 2 + widening, to: initial.maxX - 2 + widening - travel)
            }
        }
    }

    func sidebarDragLongChat() throws {
        guard seed == "perf" else { throw TourSkip(reason: "the long Bot Chats need --seed perf") }
        guard button("botRow-bot-beta").waitForExistence(timeout: 10) else { throw TourSkip(reason: "bot-beta is not in the roster") }
        try openChat(slug: "bot-beta")
        idle(2)
        try sidebarDrag()
    }

    func windowResize() throws {
        let initial = window.frame
        let origin = initial.origin
        let corner = CGPoint(x: initial.maxX - 2, y: initial.maxY - 2)
        let shrunk = CGPoint(x: corner.x - 260, y: corner.y - 160)
        try measuring {
            for pass in 0..<3 {
                point(corner.x, corner.y, origin: origin)
                    .click(forDuration: 0.1, thenDragTo: point(shrunk.x, shrunk.y, origin: origin), withVelocity: .slow, thenHoldForDuration: 0.3)
                idle(0.5)
                if pass == 0, window.frame.width >= initial.width - 20 { throw TourSkip(reason: "the window did not resize from its corner") }
                point(shrunk.x, shrunk.y, origin: origin)
                    .click(forDuration: 0.1, thenDragTo: point(corner.x, corner.y, origin: origin), withVelocity: .slow, thenHoldForDuration: 0.3)
                idle(0.5)
            }
        }
    }
}
#endif
