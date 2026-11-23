#if os(macOS)
import AppKit

enum DocumentActions {
    @MainActor
    static func save(_ data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = FileSaver.safeName(suggestedName)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            PalAlert.notice(String(localized: "The file couldn't be saved."))
        }
    }
}
#endif
