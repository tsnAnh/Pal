import HermesChat
import SwiftUI
import WebKit

enum EmbedNavigationPolicy {
    static let youtubeBase = URL(string: "https://www.youtube-nocookie.com/")!

    static func isAllowedEmbed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host(percentEncoded: false)?.lowercased()
        else { return false }
        return EmbedDetector.allowedEmbedHosts.contains(host)
    }

    static func wrapperHTML(for embedURL: URL) -> String {
        let source = embedURL.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "<", with: "%3C")
        return """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{border:0;width:100%;height:100%}</style>
        <iframe src="\(source)" allow="accelerometer; autoplay; encrypted-media; gyroscope; picture-in-picture; fullscreen" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe>
        """
    }
}

@MainActor
final class EmbedWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    var onFailure: () -> Void
    private var initialLoadFinished = false
    private var failed = false

    init(onFailure: @escaping () -> Void) {
        self.onFailure = onFailure
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        let activated = navigationAction.navigationType == .linkActivated
        if url?.scheme?.lowercased() == "about", url?.absoluteString == "about:blank" || url?.absoluteString == "about:srcdoc" {
            return .allow
        }
        if activated {
            openExternally(url)
            return .cancel
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        guard EmbedNavigationPolicy.isAllowedEmbed(url) else { return .cancel }
        if isMainFrame, initialLoadFinished { return .cancel }
        return .allow
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.navigationType == .linkActivated {
            openExternally(navigationAction.request.url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        initialLoadFinished = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func reportRejectedLoad() {
        guard !failed else { return }
        failed = true
        onFailure()
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" { return }
        reportRejectedLoad()
    }

    private func openExternally(_ url: URL?) {
        guard let url else { return }
        ExternalLink.open(url)
    }
}

@MainActor
private func embedConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    #if os(iOS)
    configuration.allowsInlineMediaPlayback = true
    #endif
    return configuration
}

@MainActor
private func startEmbedLoad(_ webView: WKWebView, descriptor: EmbedDescriptor, dark: Bool, coordinator: EmbedWebCoordinator) {
    webView.navigationDelegate = coordinator
    webView.uiDelegate = coordinator
    let url = descriptor.embedURL(dark: dark)
    guard EmbedNavigationPolicy.isAllowedEmbed(url) else {
        Task { @MainActor in coordinator.reportRejectedLoad() }
        return
    }
    if descriptor.provider == .youtube {
        webView.loadHTMLString(EmbedNavigationPolicy.wrapperHTML(for: url), baseURL: EmbedNavigationPolicy.youtubeBase)
    } else {
        webView.load(URLRequest(url: url))
    }
}

#if os(macOS)
private final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

struct EmbedWebView: NSViewRepresentable {
    let descriptor: EmbedDescriptor
    let dark: Bool
    let onFailure: () -> Void

    func makeCoordinator() -> EmbedWebCoordinator { EmbedWebCoordinator(onFailure: onFailure) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = PassthroughWebView(frame: .zero, configuration: embedConfiguration())
        startEmbedLoad(webView, descriptor: descriptor, dark: dark, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onFailure = onFailure
    }
}
#else
struct EmbedWebView: UIViewRepresentable {
    let descriptor: EmbedDescriptor
    let dark: Bool
    let onFailure: () -> Void

    func makeCoordinator() -> EmbedWebCoordinator { EmbedWebCoordinator(onFailure: onFailure) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: embedConfiguration())
        startEmbedLoad(webView, descriptor: descriptor, dark: dark, coordinator: context.coordinator)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onFailure = onFailure
    }
}
#endif
