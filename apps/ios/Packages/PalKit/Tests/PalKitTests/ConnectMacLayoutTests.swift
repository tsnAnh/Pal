import Foundation
import PalConnect
import Testing

@Suite("Connect Apps Mac layout")
struct ConnectMacLayoutTests {
    func row(_ id: String, _ category: String, _ state: ConnectRowState = .connect) -> ConnectListRow {
        let app = ConnectApp(
            id: id, name: id.capitalized, summary: "", category: category, source: .mcp(name: id, requires: []), state: .disconnected
        )
        return ConnectListRow(app: app, state: state)
    }

    func rows(_ category: String, _ count: Int, state: ConnectRowState = .connect) -> [ConnectListRow] {
        (0..<count).map { row("\(category)-\($0)", category, state) }
    }

    let device = (title: "This Mac", count: 4)

    @Test func noRecommendedAndNoBotTemplatesAndConnectedStayOutOfTheGrid() {
        let attention = row("linear", "Work management", .needsAttention(reason: "Sign-in expired"))
        let all = rows("Developer tools", 2) + rows("Finance", 1) + [row("slack", "Communication", .connected), attention]
        let sections = ConnectMacLayout.sections(
            rows: all, categories: ["Developer tools", "Work management", "Finance", "Communication"], chip: .all, isSearching: false, device: device
        )
        #expect(sections.map(\.title) == ["Needs attention", "This Mac", "Developer tools", "Finance"])
        #expect(!sections.flatMap(\.rows).contains { $0.id == "slack" })
        #expect(!sections.map(\.title).contains("Recommended for you"))
        #expect(!sections.map(\.title).contains("Bot templates"))
        #expect(!sections.map(\.title).contains("Connected"))
    }

    @Test func aConnectedRowThatJustFinishedStaysInItsCategoryUntilTheScreenCloses() {
        let all = [row("github", "Developer tools", .connected), row("sentry", "Developer tools")]
        let sections = ConnectMacLayout.sections(
            rows: all, categories: ["Developer tools"], chip: .all, isSearching: false, device: (title: "This Mac", count: 0), keeping: ["github"]
        )
        #expect(sections.flatMap(\.rows).map(\.id) == ["github", "sentry"])
    }

    @Test func aLongSectionShowsSixRowsThenViewAllExpandsInPlace() throws {
        let sections = ConnectMacLayout.sections(
            rows: rows("Developer tools", 9), categories: ["Developer tools"], chip: .all, isSearching: false, device: (title: "This Mac", count: 0)
        )
        let section = try #require(sections.first)
        #expect(section.hasViewAll)
        #expect(section.visibleCount(expanded: false) == 6)
        #expect(section.visibleCount(expanded: true) == 9)
        let short = ConnectMacSection(kind: .category("Finance"), title: "Finance", rows: rows("Finance", 6))
        #expect(!short.hasViewAll)
        #expect(short.visibleCount(expanded: false) == 6)
    }

    @Test func theThisMacChipShowsOnlyTheDeviceSectionAndACategoryChipOnlyThatCategory() {
        let all = rows("Developer tools", 2) + rows("Finance", 2)
        let categories = ["Developer tools", "Finance"]
        let mac = ConnectMacLayout.sections(rows: all, categories: categories, chip: .thisDevice, isSearching: false, device: device)
        #expect(mac.map(\.kind) == [.thisDevice])
        #expect(mac.first?.total == 4)
        let finance = ConnectMacLayout.sections(rows: all, categories: categories, chip: .category("Finance"), isSearching: false, device: device)
        #expect(finance.map(\.title) == ["Finance"])
        #expect(finance.first?.rows.count == 2)
    }

    @Test func searchingGivesOneResultsSectionAndNothingWhenNothingMatches() {
        let found = ConnectMacLayout.sections(
            rows: rows("Developer tools", 2), categories: ["Developer tools"], chip: .thisDevice, isSearching: true, device: device
        )
        #expect(found.map(\.title) == ["Results"])
        #expect(found.first?.rows.count == 2)
        #expect(ConnectMacLayout.sections(rows: [], categories: [], chip: .all, isSearching: true, device: device).isEmpty)
    }

    @Test func chipsAreTheThreeBiggestCategoriesAndTheRestGoUnderMore() {
        let all = rows("Finance", 5) + rows("Developer tools", 4) + rows("Communication", 4) + rows("Design and web", 2) + rows("Other", 1)
        let categories = ["Developer tools", "Design and web", "Finance", "Communication", "Other"]
        let bar = ConnectChipBar(rows: all, categories: categories)
        #expect(bar.leading == ["Finance", "Developer tools", "Communication"])
        #expect(bar.more == ["Design and web", "Other"])
        #expect(bar.moreIsSelected(.category("Other")))
        #expect(!bar.moreIsSelected(.category("Finance")))
        #expect(!bar.moreIsSelected(.all))
    }

    @Test func aCategoryWithOnlyConnectedAppsMakesNoChip() {
        let all = rows("Finance", 2, state: .connected) + rows("Developer tools", 1)
        let bar = ConnectChipBar(rows: all, categories: ["Developer tools", "Finance"])
        #expect(bar.leading == ["Developer tools"])
        #expect(bar.more.isEmpty)
    }

    @Test func theCountLineIsTheConnectorCountBecauseNoSkillIsTiedToAnApp() {
        #expect(ConnectCountLine.text(connectors: 1) == "1 connector")
        #expect(ConnectCountLine.text(connectors: 2) == "2 connectors")
    }

    @Test func exactlyOneCancelActionIsLiveOnEveryScreen() {
        var navigation = ConnectMacNavigation()
        #expect(navigation.screen == .apps)
        #expect(navigation.showsPanelClose)
        #expect(!navigation.showsBack)
        #expect(navigation.cancelAction == .closePanel)
        #expect(navigation.liveCancelActions == 1)

        navigation.showInstalled()
        #expect(!navigation.showsPanelClose)
        #expect(navigation.showsBack)
        #expect(navigation.cancelAction == .back)
        #expect(navigation.liveCancelActions == 1)

        navigation.back()
        #expect(navigation.cancelAction == .closePanel)
        #expect(navigation.liveCancelActions == 1)
    }
}
