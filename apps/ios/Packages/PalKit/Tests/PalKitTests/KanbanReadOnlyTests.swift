import Foundation
import PalKanban
import PalProtocol
import PalTransport
import Testing

@Suite("Kanban stays read-only")
struct KanbanReadOnlyTests {
    private static let iosRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private static let readMethods: Set<String> = [
        "kanban.boards.list", "kanban.board.snapshot", "kanban.card.get", "kanban.evidence.list", "kanban.events.since",
    ]

    private func sources(in relative: String) throws -> [(path: String, text: String)] {
        let root = Self.iosRoot.appendingPathComponent(relative)
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var found: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            found.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return found
    }

    private func kanbanClientSources() throws -> [(path: String, text: String)] {
        let wire = Self.iosRoot.appendingPathComponent("Packages/PalKit/Sources/PalTransport/KanbanWire.swift")
        return try sources(in: "App/Kanban") + sources(in: "Packages/PalKit/Sources/PalKanban")
            + [("KanbanWire.swift", try String(contentsOf: wire, encoding: .utf8))]
    }

    @Test("the five read methods are the only kanban.* strings, and only the service names them")
    func onlyReadMethodsAreNamed() throws {
        let files = try kanbanClientSources()
        #expect(files.count >= 8)
        let pattern = try Regex(#"kanban\.[A-Za-z_.]+"#)
        var named: Set<String> = []
        for (path, text) in files {
            for match in text.matches(of: pattern) {
                let method = String(text[match.range])
                named.insert(method)
                #expect(Self.readMethods.contains(method), "\(path) names \(method)")
                #expect(path == "KanbanService.swift", "\(path) must not name a gateway method")
            }
        }
        #expect(named == Self.readMethods)
        #expect(Set(KanbanService.methods) == Self.readMethods)
    }

    @Test("the UI has no write, claim, spawn, complete, merge, move or drag affordance")
    func uiHasNoWriteControls() throws {
        let files = try sources(in: "App/Kanban")
        #expect(files.count == 7)
        let verbs = try Regex(#"\b(write|claim|spawn|complete|merge|assign|create|move|drag|drop|delete|archive|unblock|approve|reject|retry)[A-Za-z]*\s*\("#)
        let modifiers = [".draggable", ".onDrag", ".onDrop", ".dropDestination", ".swipeActions", ".onMove", ".contextMenu", ".onDelete", "TextField", "TextEditor"]
        for (path, text) in files {
            #expect(text.firstMatch(of: verbs) == nil, "\(path) calls a mutating verb")
            for modifier in modifiers { #expect(!text.contains(modifier), "\(path) uses \(modifier)") }
        }
    }

    @Test("claim expiry, claim locks and receipts are not part of any client model")
    func noSecretsInModels() throws {
        let wire = try String(contentsOf: Self.iosRoot.appendingPathComponent("Packages/PalKit/Sources/PalTransport/KanbanWire.swift"), encoding: .utf8)
        for forbidden in ["claim_expires", "claimExpires", "claim_lock", "claimLock", "\"lock\"", "workspace", "digest"] {
            #expect(!wire.contains(forbidden), "KanbanWire.swift mentions \(forbidden)")
        }
    }

    @Test("the entry points are gated by the kanban capability and add no other shortcut")
    func entryPointsAreGated() throws {
        let app = Self.iosRoot.appendingPathComponent("App")
        for file in ["HomeView.swift", "Mac/MacSidebar.swift"] {
            let text = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            #expect(text.contains("router.capabilities.contains(.kanban)"), "\(file)")
            #expect(text.contains("kanbanButton"), "\(file)")
        }
        let store = try String(contentsOf: app.appendingPathComponent("Mac/MacShortcutStore.swift"), encoding: .utf8)
        #expect(!store.localizedCaseInsensitiveContains("kanban"))
    }
}
