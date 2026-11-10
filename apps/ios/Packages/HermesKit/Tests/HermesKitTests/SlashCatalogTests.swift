@testable import HermesChat
import HermesProtocol
import Testing

@Suite("Slash picker")
struct SlashCatalogTests {
    private let catalog: JSONValue = [
        "categories": [
            ["name": "Session", "pairs": [["/new", "Start a new session"], ["/model", "Switch the model"]]],
            ["name": "TUI", "pairs": [["/redraw", "Force a full UI repaint"]]],
        ],
        "pairs": [
            ["/new", "Start a new session"], ["/model", "Switch the model"], ["/redraw", "Force a full UI repaint"],
            ["/work", "Fix the leak"], ["/summarize", "Summarize a page"], ["/bundled-idle", "Never run"],
        ],
        "skills": [
            "/work": ["usage": 5, "origin": "user"],
            "/summarize": ["usage": 1, "origin": "bundled"],
            "/bundled-idle": ["usage": 0, "origin": "bundled"],
        ],
    ]

    private var items: [SlashItem] { SlashCatalog.parse(catalog) }

    @Test("a leading slash opens the picker; a mid-text slash, a space or a path closes it")
    func trigger() {
        #expect(SlashCatalog.query(in: "/") == "")
        #expect(SlashCatalog.query(in: "/mo") == "mo")
        #expect(SlashCatalog.query(in: "hi /mo") == nil)
        #expect(SlashCatalog.query(in: " /mo") == nil)
        #expect(SlashCatalog.query(in: "/model gpt") == nil)
        #expect(SlashCatalog.query(in: "/usr/local") == nil)
        #expect(SlashCatalog.query(in: "") == nil)
    }

    @Test("commands come from categories, skills from the flat list, TUI-only commands are dropped")
    func parsing() {
        #expect(items.filter { $0.group == .commands }.map(\.command) == ["/new", "/model"])
        #expect(items.filter { $0.group == .skills }.map(\.command) == ["/work", "/summarize", "/bundled-idle"])
    }

    @Test("a bare slash lists Commands then Skills by usage and hides never-run bundled skills")
    func browse() {
        #expect(SlashCatalog.filter(items, query: "").map(\.command) == ["/new", "/model", "/work", "/summarize"])
    }

    @Test("typing filters by name then description, grouped Commands before Skills")
    func filtering() {
        #expect(SlashCatalog.filter(items, query: "mo").map(\.command) == ["/model"])
        #expect(SlashCatalog.filter(items, query: "/MODEL").map(\.command) == ["/model"])
        #expect(SlashCatalog.filter(items, query: "leak").map(\.command) == ["/work"])
        #expect(SlashCatalog.filter(items, query: "idle").map(\.command) == ["/bundled-idle"])
        #expect(SlashCatalog.filter(items, query: "zzz").isEmpty)
        #expect(SlashCatalog.score(SlashItem(command: "/model", description: "x", group: .commands), "model") == 0)
        #expect(SlashCatalog.score(SlashItem(command: "/model", description: "x", group: .commands), "mod") == 1)
        #expect(SlashCatalog.score(SlashItem(command: "/model", description: "x", group: .commands), "ode") == 2)
        #expect(SlashCatalog.score(SlashItem(command: "/a", description: "summary", group: .commands), "sum") == 4)
    }

    @Test("picking a row replaces the draft with the command and a space")
    func insertion() throws {
        let model = try #require(SlashCatalog.filter(items, query: "mo").first)
        #expect(SlashCatalog.insertion(for: model) == "/model ")
        #expect(SlashCatalog.query(in: SlashCatalog.insertion(for: model)) == nil)
    }
}
