@testable import PalChat
import Foundation
import Testing

@Suite("Document viewer")
struct ViewerDocumentTests {
    private func file(_ path: String) -> FileReference { FileReference(path: path, directive: "MEDIA:\(path)") }

    private let current = FileReference(path: "/srv/docs/arena/run-a.md", directive: "MEDIA:/srv/docs/arena/run-a.md")

    private var chatFiles: [FileReference] {
        [file("/srv/docs/arena/notes/run-b.md"), file("/srv/docs/brief.md"), file("/srv/docs/report.pdf")]
    }

    @Test("markdown opens the viewer, text and code open it as plain text")
    func routing() {
        for name in ["a.md", "A.MD", "notes.markdown", "path/to/readme.md"] {
            #expect(FileOpenRoute(fileName: name, viewerShowsDocuments: true) == .viewer(.markdown), "\(name)")
        }
        for name in ["a.txt", "a.json", "main.swift", "tool.py", "app.ts", "view.tsx", "conf.yaml", "conf.yml", "x.toml", "run.sh",
                     "lib.rs", "main.go", "A.java", "a.kt", "a.rb", "a.c", "a.h", "a.cpp", "a.css", "q.sql", "a.xml", "a.js"] {
            #expect(FileOpenRoute(fileName: name, viewerShowsDocuments: true) == .viewer(.plainText), "\(name)")
        }
    }

    @Test("html opens the live viewer on every platform, even where documents use the sheet")
    func htmlRoutesToTheLiveViewer() {
        for name in ["a.html", "A.HTM", "path/to/index.html"] {
            #expect(FileOpenRoute(fileName: name, viewerShowsDocuments: true) == .html, "\(name)")
            #expect(FileOpenRoute(fileName: name, viewerShowsDocuments: false) == .html, "\(name)")
        }
    }

    @Test("csv, pdf, office, video, images and unknown types keep the sheet")
    func routingKeepsSheet() {
        for name in ["a.csv", "a.tsv", "a.pdf", "a.docx", "a.xlsx", "a.pptx", "a.mp4", "a.mov", "a.png", "a.zip", "Makefile", "noextension", "a."] {
            #expect(FileOpenRoute(fileName: name, viewerShowsDocuments: true) == .sheet, "\(name)")
        }
    }

    @Test("a viewer that shows no documents sends every file to the sheet")
    func routingOnPlatformsWithoutTheViewer() {
        #expect(FileOpenRoute(fileName: "a.md", viewerShowsDocuments: false) == .sheet)
        #expect(FileOpenRoute(fileName: "a.txt", viewerShowsDocuments: false) == .sheet)
    }

    @Test("a file under the cap shows whole, with no note")
    func underTheCap() {
        let text = DocumentText(data: Data("hello\nworld".utf8), cap: 64)
        #expect(text.text == "hello\nworld")
        #expect(!text.isTruncated)
        #expect(text.truncationNote == nil)
        #expect(text.totalBytes == 11)
    }

    @Test("a file over the cap shows its first bytes and a note about the rest")
    func overTheCap() throws {
        let data = Data(repeating: UInt8(ascii: "a"), count: 100)
        let text = DocumentText(data: data, cap: 40)
        #expect(text.text.utf8.count == 40)
        #expect(text.isTruncated)
        #expect(text.totalBytes == 100)
        let note = try #require(text.truncationNote)
        #expect(note.hasPrefix("Showing the first "))
        #expect(note.hasSuffix("Download the file to read the rest."))
    }

    @Test("the default cap is 2 MB")
    func defaultCap() {
        #expect(DocumentText.cap == 2 * 1024 * 1024)
        #expect(DocumentText(data: Data(count: DocumentText.cap)).isTruncated == false)
        #expect(DocumentText(data: Data(count: DocumentText.cap + 1)).isTruncated)
    }

    @Test("the cap never splits a multi-byte character")
    func capKeepsScalarsWhole() {
        let data = Data("aéé".utf8)
        #expect(data.count == 5)
        #expect(DocumentText(data: data, cap: 2).text == "a")
        #expect(DocumentText(data: data, cap: 3).text == "aé")
        #expect(DocumentText(data: data, cap: 4).text == "aé")
        #expect(DocumentText(data: Data("a😀".utf8), cap: 3).text == "a")
    }

    @Test("bytes that are not UTF-8 still decode")
    func invalidBytes() {
        let text = DocumentText(data: Data([0x61, 0xFF, 0x62]), cap: 10)
        #expect(text.text.hasPrefix("a"))
        #expect(!text.isEmpty)
    }

    @Test("empty and whitespace-only files are empty")
    func emptyFiles() {
        #expect(DocumentText(data: Data()).isEmpty)
        #expect(DocumentText(data: Data(" \n\t\n".utf8)).isEmpty)
        #expect(!DocumentText(data: Data("x".utf8)).isEmpty)
    }

    @Test("plain text splits into line chunks that join back to the original")
    func chunks() {
        let text = (1...450).map { "line \($0)" }.joined(separator: "\n")
        let chunks = DocumentTextChunks.split(text)
        #expect(chunks.map { $0.text.split(separator: "\n", omittingEmptySubsequences: false).count } == [200, 200, 50])
        #expect(chunks.map(\.id) == [0, 1, 2])
        #expect(chunks.map(\.text).joined(separator: "\n") == text)
    }

    @Test("a chunk also closes at its character budget, and empty text has no chunks")
    func chunkBudget() {
        let long = String(repeating: "x", count: 100)
        let chunks = DocumentTextChunks.split([long, long, long, long].joined(separator: "\n"), linesPerChunk: 200, charactersPerChunk: 150)
        #expect(chunks.count == 2)
        #expect(DocumentTextChunks.split("").isEmpty)
        #expect(DocumentTextChunks.split("one line").map(\.text) == ["one line"])
    }

    @Test("CRLF line endings split like LF")
    func crlf() {
        let chunks = DocumentTextChunks.split("a\r\nb\r\nc", linesPerChunk: 2)
        #expect(chunks.map(\.text) == ["a\nb", "c"])
    }

    @Test("a relative link to a file in this chat opens it")
    func chatFileLinks() {
        let notes = chatFiles[0]
        let brief = chatFiles[1]
        #expect(DocumentLink.classify(URL(string: "notes/run-b.md")!, from: current, chatFiles: chatFiles) == .chatFile(notes))
        #expect(DocumentLink.classify(URL(string: "./notes/run-b.md")!, from: current, chatFiles: chatFiles) == .chatFile(notes))
        #expect(DocumentLink.classify(URL(string: "notes/run-b.md#top")!, from: current, chatFiles: chatFiles) == .chatFile(notes))
        #expect(DocumentLink.classify(URL(string: "../brief.md")!, from: current, chatFiles: chatFiles) == .chatFile(brief))
        #expect(DocumentLink.classify(URL(string: "/srv/docs/brief.md")!, from: current, chatFiles: chatFiles) == .chatFile(brief))
        #expect(DocumentLink.classify(URL(fileURLWithPath: "/srv/docs/brief.md"), from: current, chatFiles: chatFiles) == .chatFile(brief))
    }

    @Test("web links go to the browser")
    func webLinks() {
        for text in ["https://example.com/a?b=1", "http://example.com", "mailto:a@example.com"] {
            let url = URL(string: text)!
            #expect(DocumentLink.classify(url, from: current, chatFiles: chatFiles) == .web(url), "\(text)")
        }
    }

    @Test("files outside this chat, odd schemes and empty links are unreachable or in-page")
    func unreachableLinks() {
        for text in ["notes/missing.md", "../../etc/passwd", "ftp://example.com/a.md", "javascript:alert(1)", "/srv/docs/other.md"] {
            #expect(DocumentLink.classify(URL(string: text)!, from: current, chatFiles: chatFiles) == .unreachable, "\(text)")
        }
        #expect(DocumentLink.classify(URL(string: "#method")!, from: current, chatFiles: chatFiles) == .sameDocument)
    }

    @Test("an unreachable link renders as plain text with a note, other links stay links")
    func hidingUnreachableLinks() {
        let source = "See [run b](notes/run-b.md), [gone](notes/missing.md) and [site](https://example.com)."
        let items = MarkdownDocument(parsing: source).layoutItems
        let rewritten = DocumentLink.hidingUnreachable(items, from: current, chatFiles: chatFiles)
        let blocks = rewritten.flatMap { item -> [MarkdownBlock] in
            switch item {
            case .block(let block): [block]
            case .quote(let blocks): blocks
            }
        }
        let links = blocks.flatMap { block in block.text.runs.compactMap { $0.link } }.map(\.absoluteString)
        #expect(links == ["notes/run-b.md", "https://example.com"])
        let text = blocks.map { String($0.text.characters) }.joined()
        #expect(text.contains("gone (File not available in this chat)"))
        #expect(!text.contains("run b ("))
    }

    @Test("a document without links is returned as it is")
    func hidingWithoutLinks() {
        let items = MarkdownDocument(parsing: "# Title\n\nbody").layoutItems
        #expect(DocumentLink.hidingUnreachable(items, from: current, chatFiles: []) == items)
    }

    @Test("markdown becomes layout items, text becomes chunks, an empty file becomes empty")
    func documentBody() {
        let markdown = ViewerDocument(data: Data("# T\n\npara".utf8), kind: .markdown, file: current, chatFiles: chatFiles)
        guard case .markdown(let items) = markdown.body else {
            Issue.record("expected markdown")
            return
        }
        #expect(!items.isEmpty)
        #expect(markdown.note == nil)

        let code = ViewerDocument(data: Data("let a = 1\nlet b = 2".utf8), kind: .plainText, file: file("/x/a.swift"), chatFiles: [])
        #expect(code.body == .plainText([DocumentTextChunk(id: 0, text: "let a = 1\nlet b = 2")]))

        let blank = ViewerDocument(data: Data("  \n".utf8), kind: .markdown, file: current, chatFiles: [])
        #expect(blank.body == .empty)
        #expect(ViewerDocument(data: Data(), kind: .plainText, file: current, chatFiles: []).body == .empty)
    }

    @Test("a document over the cap keeps its first 2 MB and carries the note")
    func documentOverTheCap() {
        let line = String(repeating: "word ", count: 40) + "\n"
        let data = Data(String(repeating: line, count: (DocumentText.cap / line.utf8.count) + 100).utf8)
        #expect(data.count > DocumentText.cap)
        let document = ViewerDocument(data: data, kind: .plainText, file: file("/x/big.txt"), chatFiles: [])
        #expect(document.note?.hasSuffix("Download the file to read the rest.") == true)
        guard case .plainText(let chunks) = document.body else {
            Issue.record("expected plain text")
            return
        }
        #expect(chunks.map(\.text.utf8.count).reduce(0, +) <= DocumentText.cap)
    }

    @Test("a viewer opens documents only, and following a link keeps the chat's files")
    func viewerState() throws {
        #expect(DocumentViewerState(file: file("/x/a.csv"), chatFiles: []) == nil)
        #expect(DocumentViewerState(file: file("/x/a.pdf"), chatFiles: []) == nil)
        let state = try #require(DocumentViewerState(file: current, chatFiles: chatFiles))
        #expect(state.title == "run-a.md")
        #expect(state.kind == .markdown)
        let next = try #require(state.opening(chatFiles[0]))
        #expect(next.file == chatFiles[0])
        #expect(next.chatFiles == chatFiles)
        #expect(state.opening(chatFiles[2]) == nil)
    }

    @Test("a document has download and close, never edit")
    func viewerActions() {
        #expect(DocumentViewerState.actions == [.download, .close])
    }

    @Test("a message about a document names the file for the bot")
    func sendBody() {
        #expect(DocumentViewerSend.body(file: current, draft: "  Summarise this \n") == "@file:/srv/docs/arena/run-a.md\nSummarise this")
        #expect(DocumentViewerSend.body(file: file("/srv/my docs/a.md"), draft: "hi") == "@file:`/srv/my docs/a.md`\nhi")
        #expect(DocumentViewerSend.body(file: current, draft: " \n ") == nil)
    }
}
