import PalChat
import SwiftUI
import WebKit

@MainActor
final class HTMLWebViewOwner {
    static let shared = HTMLWebViewOwner()

    private weak var current: WKWebView?

    func adopt(_ web: WKWebView) {
        if let previous = current, previous !== web { tearDown(previous) }
        current = web
    }

    func release(_ web: WKWebView) {
        tearDown(web)
        if current === web { current = nil }
    }

    private func tearDown(_ web: WKWebView) {
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.configuration.userContentController.removeAllContentRuleLists()
        web.loadHTMLString("", baseURL: nil)
        web.removeFromSuperview()
    }
}

@MainActor
final class HTMLWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let session: HTMLViewerSession
    private let page: URL
    private let policy: HTMLNavigationPolicy
    private var loadedGeneration = -1
    private var loadTask: Task<Void, Never>?

    init(session: HTMLViewerSession, page: URL) {
        self.session = session
        self.page = page
        policy = HTMLNavigationPolicy(page: page)
    }

    func makeWebView() -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: HTMLSandbox.makeConfiguration())
        web.navigationDelegate = self
        web.uiDelegate = self
        HTMLWebViewOwner.shared.adopt(web)
        return web
    }

    func load(_ web: WKWebView, generation: Int) {
        guard generation != loadedGeneration else { return }
        loadedGeneration = generation
        loadTask?.cancel()
        let blocked = !session.render.online
        loadTask = Task { [weak web, session, page] in
            do {
                guard let controller = web?.configuration.userContentController else { return }
                try await HTMLSandbox.setOnlineBlocked(blocked, on: controller)
            } catch is CancellationError {
                return
            } catch {
                session.webFailed(.sandbox)
                return
            }
            web?.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    func release(_ web: WKWebView) {
        loadTask?.cancel()
        HTMLWebViewOwner.shared.release(web)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        let decision: HTMLPolicyDecision
        if navigationAction.shouldPerformDownload {
            decision = policy.download(url: url)
        } else if let frame = navigationAction.targetFrame {
            decision = policy.navigation(to: url, isMainFrame: frame.isMainFrame, onlineAllowed: session.render.online)
        } else {
            decision = policy.newWindow(url: url)
        }
        session.apply(decision)
        return decision == .allow ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard navigationResponse.canShowMIMEType else {
            session.apply(policy.download(url: navigationResponse.response.url))
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        session.webFinished()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        session.webFailed(.processTerminated)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        session.apply(policy.newWindow(url: navigationAction.request.url))
        return nil
    }

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        .deny
    }

    func webView(
        _ webView: WKWebView,
        decideDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo
    ) async -> WKPermissionDecision {
        .deny
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        let cancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        let policyCancelled = nsError.domain == "WebKitErrorDomain" && nsError.code == 102
        guard !cancelled, !policyCancelled else { return }
        session.webFailed(.loadFailed)
    }
}

#if os(iOS)
struct HTMLWebSurface: UIViewRepresentable {
    let session: HTMLViewerSession
    let page: URL
    let generation: Int

    func makeCoordinator() -> HTMLWebCoordinator { HTMLWebCoordinator(session: session, page: page) }

    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeWebView() }

    func updateUIView(_ web: WKWebView, context: Context) { context.coordinator.load(web, generation: generation) }

    static func dismantleUIView(_ web: WKWebView, coordinator: HTMLWebCoordinator) { coordinator.release(web) }
}
#else
struct HTMLWebSurface: NSViewRepresentable {
    let session: HTMLViewerSession
    let page: URL
    let generation: Int

    func makeCoordinator() -> HTMLWebCoordinator { HTMLWebCoordinator(session: session, page: page) }

    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView() }

    func updateNSView(_ web: WKWebView, context: Context) { context.coordinator.load(web, generation: generation) }

    static func dismantleNSView(_ web: WKWebView, coordinator: HTMLWebCoordinator) { coordinator.release(web) }
}
#endif
