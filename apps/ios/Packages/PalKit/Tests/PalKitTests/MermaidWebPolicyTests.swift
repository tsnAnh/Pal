import Foundation
import Testing

@Suite("Mermaid web policy")
struct MermaidWebPolicyTests {
    private static let rendererURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Chat/Rich/MermaidRenderer.swift")

    private func source() throws -> String {
        try String(contentsOf: Self.rendererURL, encoding: .utf8)
    }

    @Test func rendererIsolatesItsWebViewFromTheNetworkAndStorage() throws {
        let text = try source()
        #expect(text.contains(".nonPersistent()"))
        #expect(text.contains("securityLevel: 'strict'"))
        #expect(text.contains("default-src 'none'"))
        #expect(text.contains("baseURL: nil"))
        #expect(text.contains(".cancel"))
    }

    @Test func rendererNeverNamesARemoteURL() throws {
        let text = try source()
        #expect(!text.contains("http://"))
        #expect(!text.contains("https://"))
        #expect(!text.contains("URL(string: \"http"))
        #expect(!text.contains("load(URLRequest"))
        #expect(!text.contains("javaScriptCanOpenWindowsAutomatically"))
    }
}
