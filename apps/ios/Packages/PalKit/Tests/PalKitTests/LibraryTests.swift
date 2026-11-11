import Foundation
import PalBotProfile
import PalProtocol
import Testing

@Suite("Bot library")
struct LibraryTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private static let wednesday = ISO8601DateFormatter().date(from: "2026-11-04T12:00:00Z")!

    private func item(
        _ id: String,
        kind: String = "link",
        title: String = "t",
        subtitle: String = "s",
        url: JSONValue = .null,
        assetRef: JSONValue = .null,
        at: String
    ) -> JSONValue {
        ["id": .string(id), "kind": .string(kind), "title": .string(title), "subtitle": .string(subtitle), "url": url,
         "asset_ref": assetRef, "mime": .null, "size": .null, "session_id": "s1", "occurred_at": .string(at)]
    }

    private func page(_ bots: ScriptedBots, filter: LibraryFilter = .all, before: String? = nil) async throws -> LibraryPage {
        try await LibraryService(gateway: bots.gateway).page(profile: "a", filter: filter, before: before)
    }

    @Test("list sends kind, limit, cursor and the bot name")
    func listParams() async throws {
        let bots = ScriptedBots()
        bots.script("library.list", ["items": [], "next_before": .null, "index_complete": true])
        _ = try await page(bots, filter: .links, before: "2026-11-01T00:00:00+00:00")
        #expect(bots.calls(to: "library.list").first?.params == [
            "kind": "links", "limit": 50, "before": "2026-11-01T00:00:00+00:00", "profile": "a",
        ])
    }

    @Test("a page maps links, media and files and keeps the cursor and indexing flag")
    func mapsPage() async throws {
        let bots = ScriptedBots()
        bots.script("library.list", [
            "items": [
                item("1", title: "lastpass.com", subtitle: "lastpass.com", url: "https://lastpass.com", at: "2026-11-04T08:00:00.250000+00:00"),
                item("2", kind: "media", title: "Screenshot.png", subtitle: "Image", assetRef: "ab", at: "2026-10-26T15:21:31+00:00"),
                item("3", kind: "file", title: "report.pdf", subtitle: "PDF", at: "2026-10-20T09:00:00+00:00"),
            ],
            "next_before": "2026-10-20T09:00:00+00:00",
            "index_complete": false,
        ])
        let result = try await page(bots)
        #expect(result.entries.map(\.kind) == [.link, .media, .file])
        #expect(result.nextBefore == "2026-10-20T09:00:00+00:00")
        #expect(result.indexComplete == false)
        #expect(result.entries[0].host == "lastpass.com")
        #expect(result.entries[0].isOpenable)
        #expect(result.entries[1].assetRef == "ab")
        #expect(result.entries[2].isOpenable == false)
    }

    @Test("items with an unknown kind or an unreadable timestamp are dropped")
    func dropsMalformed() async throws {
        let bots = ScriptedBots()
        bots.script("library.list", [
            "items": [
                item("1", kind: "hologram", at: "2026-11-04T08:00:00+00:00"),
                item("2", url: "https://a.example", at: "yesterday"),
                item("3", url: "https://b.example", at: "2026-11-04T08:00:00+00:00"),
            ],
        ])
        let result = try await page(bots)
        #expect(result.entries.map(\.id) == ["3"])
        #expect(result.indexComplete)
        #expect(result.nextBefore == nil)
    }

    @Test("only http and https links with a host are openable")
    func linkSafety() async throws {
        let bots = ScriptedBots()
        bots.script("library.list", [
            "items": [
                item("1", url: "javascript:alert(1)", at: "2026-11-04T08:00:00+00:00"),
                item("2", url: "file:///etc/passwd", at: "2026-11-04T08:00:00+00:00"),
                item("3", url: "https:///nohost", at: "2026-11-04T08:00:00+00:00"),
                item("4", url: "https://ok.example/a?b=1", at: "2026-11-04T08:00:00+00:00"),
            ],
        ])
        let result = try await page(bots)
        #expect(result.entries.map(\.isOpenable) == [false, false, false, true])
    }

    @Test("microsecond timestamps parse to the right instant")
    func timestamps() async throws {
        let bots = ScriptedBots()
        bots.script("library.list", ["items": [item("x", url: "https://a.example", at: "2026-11-04T08:00:00.500000+00:00")]])
        let entry = try #require(try await page(bots).entries.first)
        let base = ISO8601DateFormatter().date(from: "2026-11-04T08:00:00Z")!
        #expect(abs(entry.occurredAt.timeIntervalSince(base) - 0.5) < 0.001)
    }

    private func entry(_ id: String, _ iso: String) -> LibraryEntry {
        LibraryEntry(id: id, kind: .link, title: id, kindLabel: id, url: URL(string: "https://\(id).example"),
                     occurredAt: ISO8601DateFormatter().date(from: iso)!)
    }

    @Test("grouping splits at the start of the calendar week and keeps order")
    func grouping() {
        let entries = [
            entry("today", "2026-11-04T10:00:00Z"),
            entry("monday", "2026-11-02T00:00:00Z"),
            entry("sundayBefore", "2026-11-01T23:59:59Z"),
            entry("old", "2026-10-26T15:21:31Z"),
        ]
        let sections = LibraryGrouping.sections(entries, now: Self.wednesday, calendar: Self.calendar)
        #expect(sections.map(\.id) == [.thisWeek, .older])
        #expect(sections[0].entries.map(\.id) == ["today", "monday"])
        #expect(sections[1].entries.map(\.id) == ["sundayBefore", "old"])
        #expect(sections.map(\.id.title) == ["This week", "Older"])
    }

    @Test("empty sections are omitted")
    func groupingEmpty() {
        #expect(LibraryGrouping.sections([], now: Self.wednesday, calendar: Self.calendar).isEmpty)
        let onlyOld = LibraryGrouping.sections([entry("old", "2026-10-01T00:00:00Z")], now: Self.wednesday, calendar: Self.calendar)
        #expect(onlyOld.map(\.id) == [.older])
        let onlyRecent = LibraryGrouping.sections([entry("new", "2026-11-04T00:00:00Z")], now: Self.wednesday, calendar: Self.calendar)
        #expect(onlyRecent.map(\.id) == [.thisWeek])
    }

    @Test("subtitle is the host for links and kind with day for media and files")
    func subtitles() {
        let link = entry("lastpass", "2026-11-04T10:00:00Z")
        #expect(link.subtitle(locale: Locale(identifier: "en_US")) == "lastpass.example")
        let media = LibraryEntry(id: "m", kind: .media, title: "Shot.png", kindLabel: "Image", assetRef: "ab",
                                 occurredAt: ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z")!)
        #expect(media.subtitle(locale: Locale(identifier: "en_US")).hasPrefix("Image · "))
        #expect(media.subtitle(locale: Locale(identifier: "en_US")).contains("Oct"))
    }

    @Test("asset fetch asks for a thumbnail or the full file and decodes the bytes")
    func assetFetch() async throws {
        let bots = ScriptedBots()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        bots.script("library.asset", ["mime": "image/png", "data_base64": .string(bytes.base64EncodedString()), "size": 4])
        let service = LibraryService(gateway: bots.gateway)
        #expect(try await service.asset(profile: "a", ref: "ab", thumbnail: true) == bytes)
        #expect(try await service.asset(profile: "a", ref: "ab", thumbnail: false) == bytes)
        let calls = bots.calls(to: "library.asset")
        #expect(calls[0].params["thumbnail"] == true)
        #expect(calls[1].params["thumbnail"] == false)
        #expect(calls[1].params["asset_ref"] == "ab")
        #expect(calls[1].params["profile"] == "a")
    }

    @Test("asset with empty or invalid payload is an invalid response")
    func assetInvalid() async {
        let bots = ScriptedBots()
        bots.script("library.asset", ["mime": "image/png", "data_base64": "", "size": 0])
        await #expect(throws: BotsError.invalidResponse) {
            _ = try await LibraryService(gateway: bots.gateway).asset(profile: "a", ref: "ab", thumbnail: true)
        }
    }
}
