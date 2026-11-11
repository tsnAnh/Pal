import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
typealias MermaidImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias MermaidImage = NSImage
#endif

enum MermaidRenderError: Error {
    case tooLarge
    case timeout
    case unavailable
    case failed
}

@MainActor
final class MermaidRenderer: NSObject {
    static let shared = MermaidRenderer()

    static let maxSourceLength = 20_000
    static let timeout: Duration = .seconds(15)
    private static let idleRelease: Duration = .seconds(30)
    private static let cacheLimit = 32
    private static let padding: CGFloat = 8
    private static let maxDimension: CGFloat = 4_000

    private static let pageHTML = """
    <!doctype html><html><head><meta charset="utf-8">\
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">\
    <meta name="viewport" content="width=device-width,initial-scale=1">\
    </head><body style="margin:0"></body></html>
    """

    private static let renderScript = """
    mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default' });
    const result = await mermaid.render(id, source);
    document.body.style.background = dark ? '#121212' : '#fcfcfc';
    document.body.style.padding = pad + 'px';
    document.body.style.display = 'inline-block';
    document.body.innerHTML = result.svg;
    const svg = document.body.querySelector('svg');
    if (!svg) { throw new Error('no svg'); }
    const viewBox = svg.viewBox && svg.viewBox.baseVal;
    if (viewBox && viewBox.width > 0) {
        svg.setAttribute('width', String(viewBox.width));
        svg.setAttribute('height', String(viewBox.height));
        svg.style.maxWidth = 'none';
    }
    const box = svg.getBoundingClientRect();
    return [Math.ceil(box.width), Math.ceil(box.height)];
    """

    private struct CacheKey: Hashable {
        let source: String
        let isDark: Bool
    }

    @MainActor
    private final class Waiter<Value> {
        private var continuation: CheckedContinuation<Value, Error>?
        init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

        @discardableResult
        func resume(_ result: sending Result<Value, Error>) -> Bool {
            guard let continuation else { return false }
            self.continuation = nil
            continuation.resume(with: result)
            return true
        }
    }

    private var webView: WKWebView?
    private var loadWaiter: Waiter<Void>?
    private var allowNextNavigation = false
    private var cache: [CacheKey: MermaidImage] = [:]
    private var cacheOrder: [CacheKey] = []
    private var tail: Task<Void, Never>?
    private var pending = 0
    private var idleTask: Task<Void, Never>?
    private var renderCounter = 0

    func cachedImage(source: String, isDark: Bool) -> MermaidImage? {
        let key = CacheKey(source: source, isDark: isDark)
        guard let image = cache[key] else { return nil }
        touch(key)
        return image
    }

    func render(source: String, isDark: Bool) async throws -> MermaidImage {
        guard source.count <= Self.maxSourceLength else { throw MermaidRenderError.tooLarge }
        if let image = cachedImage(source: source, isDark: isDark) { return image }

        idleTask?.cancel()
        pending += 1
        let previous = tail
        let job = Task { () -> MermaidImage in
            await previous?.value
            return try await self.renderUncached(source: source, isDark: isDark)
        }
        tail = Task { _ = await job.result }
        defer {
            pending -= 1
            scheduleIdleRelease()
        }
        return try await job.value
    }

    private func renderUncached(source: String, isDark: Bool) async throws -> MermaidImage {
        let key = CacheKey(source: source, isDark: isDark)
        if let image = cache[key] { return image }

        let image: MermaidImage = try await withCheckedThrowingContinuation { continuation in
            let waiter = Waiter<MermaidImage>(continuation)
            let work = Task {
                do {
                    waiter.resume(.success(try await self.performRender(source: source, isDark: isDark)))
                } catch {
                    waiter.resume(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: Self.timeout)
                guard waiter.resume(.failure(MermaidRenderError.timeout)) else { return }
                work.cancel()
                self.discardWebView()
            }
        }
        store(image, for: key)
        return image
    }

    private func performRender(source: String, isDark: Bool) async throws -> MermaidImage {
        let web = try await loadedWebView()
        renderCounter += 1
        web.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let measured: Any?
        do {
            measured = try await web.callAsyncJavaScript(
                Self.renderScript,
                arguments: [
                    "source": source,
                    "dark": isDark,
                    "id": "pal-mermaid-\(renderCounter)",
                    "pad": Self.padding,
                ],
                in: nil,
                contentWorld: .page
            )
        } catch {
            throw MermaidRenderError.failed
        }
        guard let dims = measured as? [NSNumber], dims.count == 2 else { throw MermaidRenderError.failed }
        let width = min(CGFloat(truncating: dims[0]) + Self.padding * 2, Self.maxDimension)
        let height = min(CGFloat(truncating: dims[1]) + Self.padding * 2, Self.maxDimension)
        guard width > Self.padding * 2, height > Self.padding * 2 else { throw MermaidRenderError.failed }

        web.frame = CGRect(x: 0, y: 0, width: width, height: height)
        try await Task.sleep(for: .milliseconds(60))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
        do {
            return try await web.takeSnapshot(configuration: configuration)
        } catch {
            throw MermaidRenderError.failed
        }
    }

    private func loadedWebView() async throws -> WKWebView {
        if let webView, loadWaiter == nil { return webView }
        guard let script = Self.mermaidScript() else { throw MermaidRenderError.unavailable }
        let web = makeWebView(mermaidScript: script)
        webView = web
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadWaiter = Waiter(continuation)
            allowNextNavigation = true
            web.loadHTMLString(Self.pageHTML, baseURL: nil)
        }
        return web
    }

    private func makeWebView(mermaidScript: String) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(source: mermaidScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), configuration: configuration)
        web.navigationDelegate = self
        web.allowsLinkPreview = false
        #if canImport(UIKit)
        web.isUserInteractionEnabled = false
        #endif
        return web
    }

    private static func mermaidScript() -> String? {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func discardWebView() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        loadWaiter?.resume(.failure(MermaidRenderError.failed))
        loadWaiter = nil
        allowNextNavigation = false
    }

    private func scheduleIdleRelease() {
        guard pending == 0 else { return }
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: Self.idleRelease)
            guard !Task.isCancelled, self.pending == 0 else { return }
            self.discardWebView()
        }
    }

    private func store(_ image: MermaidImage, for key: CacheKey) {
        cache[key] = image
        touch(key)
        while cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    private func touch(_ key: CacheKey) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }
}

extension MermaidRenderer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard allowNextNavigation, navigationAction.targetFrame?.isMainFrame == true else { return .cancel }
        allowNextNavigation = false
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadWaiter?.resume(.success(()))
        loadWaiter = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        discardWebView()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        discardWebView()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        discardWebView()
    }
}
