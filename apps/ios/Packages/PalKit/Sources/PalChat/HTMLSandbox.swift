import Foundation
import WebKit

public enum HTMLSandboxError: Error, Equatable {
    case rulesUnavailable
}

@MainActor
public enum HTMLSandbox {
    public static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = WKUserContentController()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    public static func setOnlineBlocked(_ blocked: Bool, on controller: WKUserContentController) async throws {
        controller.removeAllContentRuleLists()
        guard blocked else { return }
        guard let store = WKContentRuleListStore.default(),
              let list = try await store.compileContentRuleList(
                forIdentifier: HTMLContentRules.identifier, encodedContentRuleList: HTMLContentRules.blockOnline
              )
        else { throw HTMLSandboxError.rulesUnavailable }
        try Task.checkCancellation()
        controller.add(list)
    }
}
