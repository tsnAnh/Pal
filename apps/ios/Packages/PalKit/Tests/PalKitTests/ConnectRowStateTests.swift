import Foundation
import PalConnect
import Testing

@Suite("Connect row state")
struct ConnectRowStateTests {
    func app(
        _ id: String, category: String = "Developer tools", summary: String = "", state: ConnectAppState = .disconnected, auth: String? = nil
    ) -> ConnectApp {
        ConnectApp(
            id: id, name: id.capitalized, summary: summary, category: category, source: .mcp(name: id, requires: []), state: state, authReason: auth
        )
    }

    @Test(arguments: [
        (ConnectRowInput(connection: .disconnected), ConnectRowState.connect),
        (ConnectRowInput(connection: .connected), .connected),
        (ConnectRowInput(connection: .disconnected, needsGuidedSetup: true, hasSetupFlow: true), .setUp),
        (ConnectRowInput(connection: .needsSetup, hasSetupFlow: true), .setUp),
        (ConnectRowInput(connection: .needsSetup), .unavailable),
        (ConnectRowInput(connection: .needsAuthorization, authReason: "  Token revoked "), .needsAttention(reason: "Token revoked")),
        (ConnectRowInput(connection: .needsAuthorization), .needsAttention(reason: "Sign-in expired")),
        (ConnectRowInput(connection: .connected, isBusy: true), .waiting(reason: "Working…")),
        (ConnectRowInput(connection: .disconnected, bot: .notInstalled), .setUp),
        (ConnectRowInput(connection: .disconnected, bot: .installed(summary: "2 bots")), .connected),
        (ConnectRowInput(connection: .disconnected, bot: .needsReinstall(summary: "Needs reinstall")), .needsAttention(reason: "Needs reinstall")),
    ])
    func everyConnectorLandsInExactlyOneState(input: ConnectRowInput, expected: ConnectRowState) {
        #expect(ConnectRowState.resolve(input) == expected)
    }

    @Test func eachStateOffersOneActionTitleOrNone() {
        #expect(ConnectRowState.connect.actionTitle == "Connect")
        #expect(ConnectRowState.setUp.actionTitle == "Set up")
        #expect(ConnectRowState.connected.actionTitle == "Connected")
        #expect(ConnectRowState.needsAttention(reason: "x").actionTitle == "Reconnect")
        #expect(ConnectRowState.waiting(reason: "x").actionTitle == nil)
        #expect(ConnectRowState.unavailable.actionTitle == nil)
    }

    @Test func aRowReadsTheStateWordsOfTheMockup() {
        let linear = app("linear", state: .needsAuthorization, auth: "Sign-in expired")
        let row = ConnectListRow(app: linear, state: ConnectRowState.resolve(ConnectRowInput(app: linear)))
        #expect(row.state == .needsAttention(reason: "Sign-in expired"))
        #expect(row.summary == "Sign-in expired")
        #expect(row.hasProblem)

        let figma = app("figma")
        #expect(ConnectListRow(app: figma, state: .setUp).summary == "One-time setup, about 5 minutes")
        #expect(ConnectListRow(app: figma, state: .setUp, botSummary: "Per bot · one-time setup").summary == "Per bot · one-time setup")
        #expect(ConnectListRow(app: figma, state: .connect).summary == "Sign in with your account")
        #expect(ConnectListRow(app: figma, state: .connected).summary == "Connected")
        #expect(ConnectListRow(app: figma, state: .unavailable).summary == "Not available yet")
    }

    @Test func aCatalogWarningStaysVisibleAndAFailedAttemptTakesPriority() {
        let risky = app("risky", summary: "Not verified: may not connect")
        #expect(ConnectListRow(app: risky, state: .connect).summary == "Not verified: may not connect")
        let failed = ConnectListRow(app: risky, state: .connect, problem: "Sign-in was cancelled.")
        #expect(failed.summary == "Sign-in was cancelled.")
        #expect(failed.hasProblem)
        #expect(!ConnectListRow(app: risky, state: .connect).hasProblem)
    }

    @Test func theListPinsAttentionThenConnectedThenCategoriesInOrder() {
        func row(_ id: String, _ category: String, _ state: ConnectRowState) -> ConnectListRow {
            ConnectListRow(app: app(id, category: category), state: state)
        }
        let rows = [
            row("cloudflare", "Hosting and infrastructure", .connect), row("figma", "Design and web", .setUp),
            row("linear", "Work management", .needsAttention(reason: "Sign-in expired")), row("vercel", "Hosting and infrastructure", .connected),
            row("supabase", "Hosting and infrastructure", .waiting(reason: "Working…")), row("odd", "Zebra", .connect),
        ]
        let sections = ConnectListLayout.sections(rows: rows, categories: ["Hosting and infrastructure", "Design and web"])
        #expect(sections.map(\.id) == ["needs-attention", "connected", "category-Hosting and infrastructure", "category-Design and web", "category-Zebra"])
        #expect(sections.map(\.title) == ["Needs attention", "Connected", "Hosting and infrastructure", "Design and web", "Zebra"])
        #expect(sections[2].rows.map(\.id) == ["cloudflare", "supabase"])
        #expect(sections.flatMap(\.rows).count == rows.count)
    }

    @Test func emptyInputGivesNoSections() {
        #expect(ConnectListLayout.sections(rows: [], categories: ["Developer tools"]).isEmpty)
    }
}
