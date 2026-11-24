import Foundation
import Testing
import WebKit
@testable import PalChat

@Suite("HTML preview sandbox")
struct HTMLPreviewTests {
    private let page = URL(fileURLWithPath: "/tmp/html-preview-1/page.html")
    private var policy: HTMLNavigationPolicy { HTMLNavigationPolicy(page: page) }

    private func rules() throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: Data(HTMLContentRules.blockOnline.utf8))
        return try #require(object as? [[String: Any]])
    }

    @Test("the rule list blocks http, https and websockets for every resource type and has no way out")
    func ruleListBlocksOnline() throws {
        let rules = try rules()
        let filters = rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        #expect(filters == ["^https?://", "^wss?://"])
        for rule in rules {
            let trigger = try #require(rule["trigger"] as? [String: Any])
            let action = try #require(rule["action"] as? [String: Any])
            #expect(action["type"] as? String == "block")
            #expect(Set(trigger.keys) == ["url-filter"], "no resource-type, domain or load-type narrowing: every load is blocked")
        }
        #expect(!HTMLContentRules.blockOnline.contains("ignore-previous-rules"))
        #expect(!HTMLContentRules.blockOnline.contains("file:"))
    }

    @MainActor
    @Test("the web view configuration has a throwaway store, no scripts and no automatic windows")
    func configurationIsSandboxed() {
        let configuration = HTMLSandbox.makeConfiguration()
        #expect(!configuration.websiteDataStore.isPersistent)
        #expect(configuration.userContentController.userScripts.isEmpty)
        #expect(!configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(HTMLSandbox.makeConfiguration().websiteDataStore !== configuration.websiteDataStore)
    }

    @Test("the page itself and its own anchors load; any other file does not")
    func fileNavigation() {
        #expect(policy.navigation(to: page, isMainFrame: true, onlineAllowed: false) == .allow)
        #expect(policy.navigation(to: URL(string: page.absoluteString + "#top"), isMainFrame: true, onlineAllowed: false) == .allow)
        #expect(policy.navigation(to: URL(fileURLWithPath: "/etc/passwd"), isMainFrame: true, onlineAllowed: false) == .cancel)
        #expect(policy.navigation(to: URL(fileURLWithPath: "/tmp/html-preview-1/other.html"), isMainFrame: false, onlineAllowed: true) == .cancel)
        #expect(policy.navigation(to: nil, isMainFrame: true, onlineAllowed: true) == .cancel)
    }

    @Test("links leave the page only behind a confirmation")
    func linksConfirm() throws {
        for text in ["https://example.com/a", "http://example.com", "mailto:a@example.com", "tel:+15555550100"] {
            let url = try #require(URL(string: text))
            let decision = policy.navigation(to: url, isMainFrame: true, onlineAllowed: true)
            #expect(decision == .confirmOpen(HTMLExternalOpen(url: url, reason: .link)), text)
        }
        for text in ["javascript:alert(1)", "data:text/html,hi", "blob:null/1", "sms:1", "ftp://example.com/a", "itms-apps://x"] {
            let url = try #require(URL(string: text))
            #expect(policy.navigation(to: url, isMainFrame: true, onlineAllowed: true) == .cancel, text)
        }
    }

    @Test("frames load web content only while online is allowed, and only embedded data otherwise")
    func subframes() throws {
        let web = try #require(URL(string: "https://example.com/frame"))
        #expect(policy.navigation(to: web, isMainFrame: false, onlineAllowed: false) == .cancel)
        #expect(policy.navigation(to: web, isMainFrame: false, onlineAllowed: true) == .allow)
        #expect(policy.navigation(to: URL(string: "about:blank"), isMainFrame: false, onlineAllowed: false) == .allow)
        #expect(policy.navigation(to: URL(string: "about:srcdoc"), isMainFrame: false, onlineAllowed: false) == .allow)
        #expect(policy.navigation(to: URL(string: "data:text/html,x"), isMainFrame: false, onlineAllowed: false) == .allow)
        #expect(policy.navigation(to: URL(string: "data:text/html,x"), isMainFrame: true, onlineAllowed: false) == .cancel)
    }

    @Test("new windows and downloads are denied, and offered to the browser only for web addresses")
    func windowsAndDownloads() throws {
        let web = try #require(URL(string: "https://example.com/file.zip"))
        #expect(policy.newWindow(url: web) == .confirmOpen(HTMLExternalOpen(url: web, reason: .newWindow)))
        #expect(policy.download(url: web) == .confirmOpen(HTMLExternalOpen(url: web, reason: .download)))
        for url in [nil, URL(string: "blob:null/1"), URL(string: "data:text/plain,x"), URL(fileURLWithPath: "/tmp/a")] {
            #expect(policy.newWindow(url: url) == .blocked(.newWindow))
            #expect(policy.download(url: url) == .blocked(.download))
        }
    }

    @Test("the confirmation words match the owner's wording")
    func confirmationText() throws {
        let web = try #require(URL(string: "https://example.com"))
        #expect(HTMLExternalOpen(url: web, reason: .link).question == "Open this link in your browser?")
        #expect(HTMLExternalOpen(url: page, reason: .page).question == "Open this page in your browser?")
        #expect(HTMLBlockedAction.download.notice == "A download was blocked.")
    }

    @Test("a page over five megabytes is not rendered live")
    func liveRenderCeiling() {
        #expect(HTMLPreviewLimits.liveRenderBytes == 5_000_000)
        #expect(HTMLPreviewLimits.allowsLiveRender(size: 5_000_000))
        #expect(!HTMLPreviewLimits.allowsLiveRender(size: 5_000_001))
        #expect(HTMLPreviewLimits.liveRenderBytes < MediaLimits.thumbnailSourceBytes)
    }

    @Test("online starts blocked, toggles with a reload each time, and Block again reverses it")
    func onlineToggle() {
        var state = HTMLRenderState()
        #expect(!state.toggleOnline(), "nothing to reload before the page starts")
        #expect(state.begin())
        #expect(state.phase == .loading)
        #expect(!state.online)
        #expect(state.onlineLabel == "Online blocked")
        #expect(state.onlineActionLabel == "Allow online")
        state.finish()
        #expect(state.phase == .ready)
        let loaded = state.generation
        #expect(state.toggleOnline())
        #expect(state.online)
        #expect(state.phase == .loading)
        #expect(state.generation == loaded + 1)
        #expect(state.onlineLabel == "Online allowed")
        #expect(state.onlineActionLabel == "Block again")
        state.finish()
        #expect(state.toggleOnline())
        #expect(!state.online)
        #expect(state.generation == loaded + 2)
    }

    @Test("a failed load keeps the online choice and Retry reloads once")
    func failureAndRetry() {
        var state = HTMLRenderState()
        state.fail(.timedOut)
        #expect(state.phase == .idle, "nothing fails before it starts")
        #expect(state.begin())
        #expect(!state.begin(), "a second start is ignored")
        #expect(!state.retry(), "a loading page has nothing to retry")
        state.fail(.timedOut)
        #expect(state.phase == .failed(.timedOut))
        #expect(HTMLRenderState.Failure.timedOut.message == "The page took too long to load.")
        let failed = state.generation
        #expect(state.retry())
        #expect(state.phase == .loading)
        #expect(state.generation == failed + 1)
        state.finish()
        state.fail(.processTerminated)
        #expect(state.phase == .failed(.processTerminated))
        #expect(state.toggleOnline(), "Allow online also reloads a failed page")
        #expect(state.online)
        #expect(state.phase == .loading)
    }

    @Test("a late finish or failure never overrides a settled state")
    func settledStatesHold() {
        var state = HTMLRenderState()
        _ = state.begin()
        state.fail(.loadFailed)
        state.finish()
        #expect(state.phase == .failed(.loadFailed))
        state.fail(.sandbox)
        #expect(state.phase == .failed(.loadFailed))
    }
}
