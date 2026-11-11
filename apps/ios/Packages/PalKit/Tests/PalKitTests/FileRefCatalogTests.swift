@testable import PalChat
import PalProtocol
import Testing

@Suite("File reference picker")
struct FileRefCatalogTests {
    private let result: JSONValue = [
        "items": [
            ["text": "@file:src/main.swift", "display": "main.swift", "meta": ""],
            ["text": "@folder:src/Views/", "display": "Views/", "meta": "dir"],
            ["text": "@file:docs/My Notes.md", "display": "My Notes.md", "meta": ""],
            ["text": "@file:", "display": "@file:", "meta": "Attach a file reference"],
            ["text": "@diff", "display": "@diff", "meta": "Git diff"],
            ["text": "@file:src/main.swift", "display": "main.swift", "meta": ""],
        ],
    ]

    private var items: [FileRefItem] { FileRefCatalog.parse(result) }

    private func trigger(_ draft: String) throws -> FileRefTrigger {
        try #require(FileRefCatalog.trigger(in: draft))
    }

    @Test("an @ at the start or after whitespace opens the picker; mid-word and finished tokens do not")
    func triggerPlacement() throws {
        #expect(try trigger("@").word == "@")
        #expect(try trigger("@src/ma").query == "src/ma")
        #expect(try trigger("look at @src").query == "src")
        #expect(try trigger("line one\n@Pac").query == "Pac")
        #expect(FileRefCatalog.trigger(in: "me@host") == nil)
        #expect(FileRefCatalog.trigger(in: "a@b.com") == nil)
        #expect(FileRefCatalog.trigger(in: "@src/main.swift ") == nil)
        #expect(FileRefCatalog.trigger(in: "@a@b") == nil)
        #expect(FileRefCatalog.trigger(in: "") == nil)
        #expect(FileRefCatalog.trigger(in: "no at here") == nil)
    }

    @Test("the slash picker's tokens never open the file picker")
    func slashIsSeparate() throws {
        #expect(FileRefCatalog.trigger(in: "/work") == nil)
        #expect(FileRefCatalog.trigger(in: "/@x") == nil)
        #expect(SlashCatalog.query(in: "/work @src") == nil)
        #expect(try trigger("/work @src").query == "src")
    }

    @Test("composed Vietnamese text inside the token stays one token")
    func vietnamese() throws {
        #expect(try trigger("mở @đường/dẫn").query == "đường/dẫn")
        #expect(try trigger("@tệp").tokenLength == 4)
    }

    @Test("a typed scope is split from the path")
    func scope() throws {
        let scoped = try trigger("@folder:src/V")
        #expect(scoped.scope == "folder")
        #expect(scoped.value == "src/V")
        #expect(scoped.word == "@folder:src/V")
        #expect(try trigger("@src").scope == nil)
        #expect(try trigger("@url:x").scope == nil)
    }

    @Test("rows are classified, duplicates dropped, gateway order kept")
    func parsing() {
        #expect(items.map(\.kind) == [.file, .folder, .file, .starter, .other])
        #expect(items.map(\.text) == ["@file:src/main.swift", "@folder:src/Views/", "@file:docs/My Notes.md", "@file:", "@diff"])
        #expect(items[1].value == "src/Views/")
        #expect(FileRefCatalog.parse(["items": []]).isEmpty)
        #expect(FileRefCatalog.parse(.string("nope")).isEmpty)
    }

    @Test("narrowing keeps rows containing the last typed segment")
    func filtering() throws {
        let all = items
        #expect(FileRefCatalog.filter(all, trigger: try trigger("@")).count == all.count)
        #expect(FileRefCatalog.filter(all, trigger: try trigger("@MAIN")).map(\.display) == ["main.swift"])
        #expect(FileRefCatalog.filter(all, trigger: try trigger("@src/Vi")).map(\.display) == ["Views/"])
        #expect(FileRefCatalog.filter(all, trigger: try trigger("@src/")).count == all.count)
        #expect(FileRefCatalog.filter(all, trigger: try trigger("@zzz")).isEmpty)
    }

    @Test("an answer is current for its own word, narrowed for a longer one, and stale for any other")
    func staleness() throws {
        let answer = FileRefResult(word: "@src", items: items)
        #expect(FileRefCatalog.visible(answer, for: try trigger("@src")).count == items.count)
        #expect(FileRefCatalog.visible(answer, for: try trigger("@src/Vi")).map(\.display) == ["Views/"])
        #expect(FileRefCatalog.visible(answer, for: try trigger("@")).isEmpty)
        #expect(FileRefCatalog.visible(answer, for: try trigger("@docs")).isEmpty)
        #expect(FileRefCatalog.visible(nil, for: try trigger("@src")).isEmpty)
        #expect(FileRefCatalog.isSettled(answer, for: try trigger("@src")))
        #expect(!FileRefCatalog.isSettled(answer, for: try trigger("@src/")))
        #expect(!FileRefCatalog.isSettled(nil, for: try trigger("@src")))
    }

    @Test("a file is inserted as @file:path and a space, replacing only the token")
    func insertFile() throws {
        let draft = "read @src/ma"
        let pick = FileRefCatalog.replacement(in: draft, trigger: try trigger(draft), item: items[0])
        #expect(pick.draft == "read @file:src/main.swift ")
        #expect(!pick.keepsOpen)
        #expect(FileRefCatalog.trigger(in: pick.draft) == nil)
    }

    @Test("paths with spaces are backtick-quoted")
    func quoting() throws {
        let pick = FileRefCatalog.replacement(in: "@My", trigger: try trigger("@My"), item: items[2])
        #expect(pick.draft == "@file:`docs/My Notes.md` ")
        #expect(FileRefCatalog.formatValue("a`b c") == "\"a`b c\"")
        #expect(FileRefCatalog.formatValue("a`b\"c d") == "'a`b\"c d'")
        #expect(FileRefCatalog.formatValue("plain/path.txt") == "plain/path.txt")
    }

    @Test("Return commits a folder as @folder:path/; Tab walks into it")
    func folders() throws {
        let draft = "@src/Vi"
        let commit = FileRefCatalog.replacement(in: draft, trigger: try trigger(draft), item: items[1])
        #expect(commit.draft == "@folder:src/Views/ ")
        let descend = FileRefCatalog.replacement(in: draft, trigger: try trigger(draft), item: items[1], descend: true)
        #expect(descend.draft == "@src/Views/")
        #expect(descend.keepsOpen)
        #expect(try trigger(descend.draft).word == "@src/Views/")
        let scoped = "@folder:sr"
        let scopedDescend = FileRefCatalog.replacement(in: scoped, trigger: try trigger(scoped), item: items[1], descend: true)
        #expect(scopedDescend.draft == "@folder:src/Views/")
    }

    @Test("Tab on a file commits it; a starter stays open; a handle is inserted as is")
    func otherRows() throws {
        let file = FileRefCatalog.replacement(in: "@m", trigger: try trigger("@m"), item: items[0], descend: true)
        #expect(file.draft == "@file:src/main.swift ")
        let starter = FileRefCatalog.replacement(in: "x @fi", trigger: try trigger("x @fi"), item: items[3])
        #expect(starter.draft == "x @file:")
        #expect(starter.keepsOpen)
        #expect(try trigger(starter.draft).scope == "file")
        let handle = FileRefCatalog.replacement(in: "@di", trigger: try trigger("@di"), item: items[4])
        #expect(handle.draft == "@diff ")
        #expect(!handle.keepsOpen)
    }
}
