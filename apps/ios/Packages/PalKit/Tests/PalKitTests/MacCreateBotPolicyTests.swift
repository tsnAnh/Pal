import Foundation
import Testing

@Suite("Mac create bot dialog policy")
struct MacCreateBotPolicyTests {
    private static let appRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.appRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func theMacDialogHasNoStartFromOrImportRow() throws {
        let text = try source("Mac/MacCreateBot.swift")
        for banned in ["CreateBotSourceRow", "CreateBotImportRow", "TemplateImportModel", "importer", "cloneFrom", "dice"] {
            #expect(!text.contains(banned), "MacCreateBot.swift mentions \(banned)")
        }
    }

    @Test func theMacModalHostNoLongerCarriesTheTemplateImport() throws {
        #expect(!(try source("Mac/MacModals.swift")).contains("templateImport"))
    }

    @Test func theMacDialogCreatesWithoutACloneSource() throws {
        #expect(try source("Mac/MacCreateBot.swift").contains("startsFresh: true"))
    }

    @Test func onlyThePreviewIsAnimatedAndShapesAreStatic() throws {
        let text = try source("Mac/MacCreateBot.swift")
        #expect(text.components(separatedBy: "BotAvatarView(").count - 1 == 1)
        #expect(text.contains("animated: false"))
        #expect(text.contains("CreateBotPreview("))
    }

    @Test func theCloseButtonMovesOnlyForTheCreateDialog() throws {
        let host = try source("Mac/MacModals.swift")
        #expect(host.components(separatedBy: "closePlacement: .trailing").count - 1 == 1)
        let panel = try source("Mac/MacModalSupport.swift")
        #expect(panel.contains("var closePlacement = MacPanelClosePlacement.leading"))
    }
}
