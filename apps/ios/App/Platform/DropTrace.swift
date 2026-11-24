#if os(macOS)
import AppKit
import PalChat
import PalDiagnostics

@MainActor
enum DropTrace {
    static let diagnostics = Diagnostics.osLog()

    private static let oncePerSession: Set<String> = ["validate", "update"]
    private static var seen: Set<String> = []

    static func reset() {
        seen = []
    }

    static func note(_ stage: String, items: [[String]], destination: String, verdict: String, refusal: String? = nil) {
        if oncePerSession.contains(stage), !seen.insert(stage).inserted { return }
        let sources = items.map { DropSource.classify(typeIdentifiers: $0).label }
        let pasteboard = NSPasteboard(name: .drag).types?.map(\.rawValue) ?? []
        let responder = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        let reason = refusal.map { " reason=\($0)" } ?? ""
        let summary = "items=\(items.count) sources=\(sources) pasteboard=\(pasteboard) destination=\(destination) responder=\(responder)"
        diagnostics.notice("attachments", "drop \(stage) verdict=\(verdict)\(reason) \(summary)")
    }
}
#endif
