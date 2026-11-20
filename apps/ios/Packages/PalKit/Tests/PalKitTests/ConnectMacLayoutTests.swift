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

    func featuredRow(_ id: String, _ category: String, _ state: ConnectRowState = .connect) -> ConnectListRow {
        let entry = PalCatalogEntry(slug: id, name: id.capitalized, category: category, method: .none, featured: true)
        let app = ConnectApp(
            id: id, name: id.capitalized, summary: "", category: category, source: .catalog(entry), state: .disconnected
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

    private static let categories = ["Developer tools", "Design and web", "Finance", "Communication", "Other"]

    private func phoneSections(
        _ all: [ConnectListRow], chip: ConnectChip = .all, device: (title: String, count: Int) = (title: "This iPhone", count: 3),
        searching: Bool = false, keeping: Set<String> = [], includesFeatured: Bool = true
    ) -> [ConnectMacSection] {
        ConnectMacLayout.sections(
            rows: all, categories: Self.categories, chip: chip, isSearching: searching, device: device, keeping: keeping,
            includesFeatured: includesFeatured
        )
    }

    @Test func needsAttentionLeadsThenThisDeviceThenFeaturedThenCategories() {
        let attention = row("linear", "Work management", .needsAttention(reason: "Sign-in expired"))
        let all = [attention, featuredRow("github", "Developer tools")] + rows("Finance", 2) + rows("Developer tools", 1)
        let sections = phoneSections(all)
        #expect(sections.map(\.kind) == [.needsAttention, .thisDevice, .featured, .category("Developer tools"), .category("Finance")])
        #expect(sections.map(\.title) == ["Needs attention", "This iPhone", "Featured", "Developer tools", "Finance"])
    }

    @Test func theDeviceSectionExistsOnlyWithADeviceCountAndItsChipShowsOnlyIt() {
        let all = [featuredRow("github", "Developer tools")] + rows("Finance", 1)
        #expect(!phoneSections(all, device: (title: "This iPhone", count: 0)).map(\.kind).contains(.thisDevice))
        #expect(phoneSections(all, chip: .thisDevice).map(\.kind) == [.thisDevice])
        #expect(phoneSections(all, chip: .thisDevice, device: (title: "This iPhone", count: 0)).isEmpty)
    }

    @Test func categoryChipsRankByUnconnectedCountAndTheTopThreeLeadWithTheRestUnderMore() {
        let all = rows("Finance", 5) + [featuredRow("github", "Developer tools"), featuredRow("figma", "Design and web", .connected)]
            + rows("Developer tools", 3) + rows("Communication", 4) + rows("Design and web", 1) + rows("Other", 1)
            + rows("Hidden", 2, state: .connected)
        let bar = ConnectChipBar(rows: all, categories: Self.categories)
        #expect(bar.leading == ["Finance", "Developer tools", "Communication"])
        #expect(bar.more == ["Design and web", "Other"])
        #expect(!(bar.leading + bar.more).contains("Hidden"))
    }

    @Test func aSectionTitleSelectsTheChipItBelongsToAndAttentionAndResultsSelectNone() {
        #expect(ConnectMacSection.Kind.needsAttention.chip == nil)
        #expect(ConnectMacSection.Kind.results.chip == nil)
        #expect(ConnectMacSection.Kind.thisDevice.chip == .thisDevice)
        #expect(ConnectMacSection.Kind.featured.chip == .featured)
        #expect(ConnectMacSection.Kind.category("Finance").chip == .category("Finance"))
        #expect(ConnectMacSection(kind: .featured, title: "Featured").id == "featured")
    }

    @Test func theFeaturedSectionAppearsOnlyWhenAFeaturedRowExists() {
        let plain = rows("Developer tools", 2) + rows("Finance", 1)
        #expect(!phoneSections(plain).map(\.kind).contains(.featured))
        #expect(phoneSections(plain + [featuredRow("github", "Developer tools")]).map(\.kind).contains(.featured))
    }

    @Test func aConnectedFeaturedRowStaysInFeaturedAndEveryFeaturedRowLeavesItsCategory() throws {
        let all = [featuredRow("github", "Developer tools", .connected), featuredRow("sentry", "Developer tools"), row("vercel", "Developer tools")]
        let sections = phoneSections(all)
        let featured = try #require(sections.first { $0.kind == .featured })
        #expect(featured.rows.map(\.id) == ["github", "sentry"])
        let category = try #require(sections.first { $0.kind == .category("Developer tools") })
        #expect(category.rows.map(\.id) == ["vercel"])
        let ids = sections.flatMap(\.rows).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func aCategoryWhoseRowsAreAllFeaturedDisappearsFromTheAllView() {
        let sections = phoneSections([featuredRow("github", "Developer tools"), row("stripe", "Finance")])
        #expect(sections.map(\.kind) == [.thisDevice, .featured, .category("Finance")])
    }

    @Test func aFeaturedRowThatNeedsAttentionShowsOnceUnderNeedsAttention() {
        let broken = featuredRow("github", "Developer tools", .needsAttention(reason: "Sign-in expired"))
        let sections = phoneSections([broken, row("vercel", "Developer tools")])
        #expect(sections.map(\.kind) == [.needsAttention, .thisDevice, .category("Developer tools")])
        #expect(sections.flatMap(\.rows).map(\.id) == ["github", "vercel"])
    }

    @Test func theFeaturedChipShowsJustTheFeaturedSectionWithConnectedRowsIncluded() {
        let all = [featuredRow("github", "Developer tools", .connected), featuredRow("figma", "Design and web"), row("stripe", "Finance")]
        let sections = phoneSections(all, chip: .featured)
        #expect(sections.map(\.kind) == [.featured])
        #expect(sections.first?.rows.map(\.id) == ["github", "figma"])
        #expect(phoneSections([row("stripe", "Finance")], chip: .featured).isEmpty)
    }

    @Test func aCategoryChipAndKeptConnectedRowsBehaveAsBeforeWhenFeaturedIsOn() {
        let all = [featuredRow("github", "Developer tools"), row("vercel", "Developer tools", .connected), row("stripe", "Finance")]
        let developer = phoneSections(all, chip: .category("Developer tools"), keeping: ["vercel"])
        #expect(developer.map(\.kind) == [.category("Developer tools")])
        #expect(developer.first?.rows.map(\.id) == ["github", "vercel"])
    }

    @Test func withFeaturedOffTheOutputIsTheOldOneAndTheFeaturedChipActsAsAll() {
        let all = [row("linear", "Work management", .needsAttention(reason: "x")), featuredRow("github", "Developer tools"), row("stripe", "Finance")]
        let old = ConnectMacLayout.sections(rows: all, categories: Self.categories, chip: .all, isSearching: false, device: device)
        let off = phoneSections(all, device: device, includesFeatured: false)
        #expect(off == old)
        #expect(off.map(\.kind) == [.needsAttention, .thisDevice, .category("Developer tools"), .category("Finance")])
        #expect(phoneSections(all, chip: .featured, device: device, includesFeatured: false) == old)
    }

    @Test func searchingGivesOneResultsSectionNoFeaturedAndNothingWhenNothingMatches() {
        let all = [featuredRow("github", "Developer tools"), row("vercel", "Developer tools")]
        let found = phoneSections(all, searching: true)
        #expect(found.map(\.kind) == [.results])
        #expect(found.first?.rows.map(\.id) == ["github", "vercel"])
        #expect(phoneSections([], searching: true).isEmpty)
        #expect(phoneSections([row("slack", "Communication", .connected)], searching: true).isEmpty)
    }

    @Test func theConnectedCountIsConnectedRowsPlusAllowedDeviceAccess() {
        let all = [
            row("a", "Finance", .connected), row("b", "Finance"), featuredRow("c", "Finance", .connected),
            row("d", "Finance", .needsAttention(reason: "x")),
        ]
        #expect(ConnectMacLayout.connectedCount(rows: all, devicesAllowed: 2) == 4)
        #expect(ConnectMacLayout.connectedCount(rows: [], devicesAllowed: 0) == 0)
        #expect(ConnectMacLayout.connectedCount(rows: [row("b", "Finance")], devicesAllowed: 1) == 1)
    }

    @Test func aFeaturedCatalogEntryMakesAFeaturedRowAndOtherSourcesNever() {
        #expect(featuredRow("github", "Developer tools").featured)
        #expect(!row("github", "Developer tools").featured)
        let custom = ConnectApp(id: "x", name: "X", summary: "", category: "Custom", source: .googleWorkspace, state: .disconnected)
        #expect(!ConnectListRow(app: custom, state: .connect).featured)
    }
}
