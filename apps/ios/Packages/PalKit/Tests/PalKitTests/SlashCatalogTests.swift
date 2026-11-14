@testable import PalChat
import PalProtocol
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

    @Test("only flat-list skills survive: categorised and TUI registry commands never reappear")
    func parsing() {
        #expect(items.map(\.command) == ["/work", "/summarize", "/bundled-idle"])
        #expect(items.map(\.group) == [.skills, .skills, .skills])
    }

    @Test("skills keep usage and bundled-origin metadata")
    func metadata() {
        #expect(items.map(\.usage) == [5, 1, 0])
        #expect(items.map(\.isUnusedBundled) == [false, false, true])
    }

    @Test("a bare slash lists skills by usage and hides never-run bundled skills")
    func browse() {
        #expect(SlashCatalog.filter(items, query: "").map(\.command) == ["/work", "/summarize"])
    }

    @Test("typing filters skills by name then description and never returns a registry command")
    func filtering() {
        #expect(SlashCatalog.filter(items, query: "mo").isEmpty)
        #expect(SlashCatalog.filter(items, query: "/MODEL").isEmpty)
        #expect(SlashCatalog.filter(items, query: "redraw").isEmpty)
        #expect(SlashCatalog.filter(items, query: "new").isEmpty)
        #expect(SlashCatalog.filter(items, query: "leak").map(\.command) == ["/work"])
        #expect(SlashCatalog.filter(items, query: "idle").map(\.command) == ["/bundled-idle"])
        #expect(SlashCatalog.filter(items, query: "zzz").isEmpty)
        #expect(SlashCatalog.score(SlashItem(command: "/work", description: "x", group: .skills), "work") == 0)
        #expect(SlashCatalog.score(SlashItem(command: "/work", description: "x", group: .skills), "wor") == 1)
        #expect(SlashCatalog.score(SlashItem(command: "/work", description: "x", group: .skills), "ork") == 2)
        #expect(SlashCatalog.score(SlashItem(command: "/a", description: "summary", group: .skills), "sum") == 4)
    }

    @Test("a registry command repeated with different case in the flat list stays excluded")
    func caseInsensitiveDuplicate() {
        let result: JSONValue = [
            "categories": [["name": "TUI", "pairs": [["/Redraw", "Repaint"]]]],
            "pairs": [["/redraw", "Repaint"], ["/Work", "Fix the leak"]],
        ]
        #expect(SlashCatalog.parse(result).map(\.command) == ["/Work"])
    }

    @Test("picking a skill replaces the draft with its command and a space")
    func insertion() throws {
        let work = try #require(SlashCatalog.filter(items, query: "wo").first)
        #expect(SlashCatalog.insertion(for: work) == "/work ")
        #expect(SlashCatalog.query(in: SlashCatalog.insertion(for: work)) == nil)
    }
}
