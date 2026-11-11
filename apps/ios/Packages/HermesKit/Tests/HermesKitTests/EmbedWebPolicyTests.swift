import Foundation
import Testing

@Suite("Embed web view policy")
struct EmbedWebPolicyTests {
    private static let source: String = {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Chat/Rich/EmbedWebView.swift")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }()

    @Test func sourceIsReadable() {
        #expect(!Self.source.isEmpty)
    }

    @Test func usesNonPersistentDataStore() {
        #expect(Self.source.contains(".nonPersistent()"))
        #expect(!Self.source.contains(".default()"))
    }

    @Test func navigationDecisionHandlerCancels() {
        #expect(Self.source.contains("decidePolicyFor navigationAction"))
        #expect(Self.source.contains(".cancel"))
        #expect(Self.source.contains("createWebViewWith"))
    }

    @Test func escapedLinksOpenInTheSystemBrowser() {
        #expect(Self.source.contains("ExternalLink.open"))
        #expect(!Self.source.contains("SFSafariViewController"))
        #expect(!Self.source.contains("inAppBrowser("))
    }

    @Test func noUserScriptsOrCustomHeaders() {
        #expect(!Self.source.contains("WKUserScript"))
        #expect(!Self.source.contains("setValue(forHTTPHeaderField"))
        #expect(!Self.source.contains("addValue("))
    }
}
