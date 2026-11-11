import Foundation
import Testing

@Suite("External link policy")
struct ExternalLinkPolicyTests {
    private static let appRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")

    private static let webSurfaces = ["SFSafariViewController", "WKWebView", "WebPage(", "inAppBrowser(", "ASWebAuthenticationSession("]
    private static let allowed: [String: Set<String>] = [
        "Platform/InAppBrowser.swift": ["SFSafariViewController", "WebPage(", "inAppBrowser("],
        "Profile/LibraryView.swift": ["inAppBrowser("],
        "WebAuthenticationBrowser.swift": ["ASWebAuthenticationSession("],
    ]

    private func swiftSources() throws -> [(path: String, text: String)] {
        let root = Self.appRoot
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var found: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            found.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return found
    }

    @Test func webSurfacesAreConfinedToTheirAllowlist() throws {
        let sources = try swiftSources()
        #expect(sources.contains { $0.path == "Platform/InAppBrowser.swift" })
        for (path, text) in sources {
            for surface in Self.webSurfaces where text.contains(surface) {
                #expect(Self.allowed[path]?.contains(surface) == true, "\(path) uses \(surface) outside the allowlist")
            }
        }
    }

    @Test func signInAndAddToFlowsNeverUseTheInAppBrowser() throws {
        for (path, text) in try swiftSources() where path.hasPrefix("Profile/Slack") || path.hasPrefix("ConnectApps/") {
            #expect(!text.contains("inAppBrowser("), "\(path) must open sign-in links with ExternalLink.open")
            #expect(!text.contains("SFSafariViewController"), "\(path)")
        }
    }

    @Test func suggestionViewsGoThroughTheSharedGate() throws {
        let sources = try swiftSources()
        for path in ["Mac/MacInspector.swift", "Profile/BotProfileView.swift"] {
            let text = try #require(sources.first { $0.path == path }?.text)
            #expect(text.contains("ProfileSuggestion"), "\(path) must build suggestions through ProfileSuggestion")
            #expect(!text.contains("\"Add to Slack\"") || text.contains("visibleSuggestions"), "\(path)")
        }
    }
}
