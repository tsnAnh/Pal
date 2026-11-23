import PalDesign
import SwiftUI

private struct BrowserTarget: Identifiable {
    let url: URL

    var id: URL { url }
}

extension View {
    func inAppBrowser(url: Binding<URL?>, onDismiss: (() -> Void)? = nil) -> some View {
        modifier(InAppBrowserModifier(url: url, onDismiss: onDismiss))
    }
}

private struct InAppBrowserModifier: ViewModifier {
    @Binding var url: URL?
    let onDismiss: (() -> Void)?

    private var target: Binding<BrowserTarget?> {
        Binding(get: { url.map(BrowserTarget.init) }, set: { if $0 == nil { url = nil } })
    }

    #if os(iOS)
    func body(content: Content) -> some View {
        content.fullScreenCover(item: target, onDismiss: onDismiss) { target in
            SafariView(url: target.url).ignoresSafeArea()
        }
    }
    #elseif os(macOS)
    func body(content: Content) -> some View {
        content.sheet(item: target, onDismiss: onDismiss) { target in
            BrowserSheet(url: target.url)
        }
    }
    #endif
}

#if os(iOS)
import SafariServices

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#elseif os(macOS)
import WebKit

private struct BrowserSheet: View {
    let url: URL

    var body: some View {
        if #available(macOS 26, *) {
            WebPageBrowser(url: url)
        } else {
            WebKitBrowser(url: url)
        }
    }
}

private struct BrowserFrame<Page: View>: View {
    let title: String
    @ViewBuilder let page: Page

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            page
                .navigationTitle(title) // nav-chrome: ok
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { // nav-chrome: ok
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("browserDone")
                    }
                }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 560, idealHeight: 720)
        .palEscape(.native) { dismiss() }
    }
}

@available(macOS 26, *)
private struct WebPageBrowser: View {
    let url: URL

    @State private var page = WebPage()

    var body: some View {
        BrowserFrame(title: page.title) { WebView(page) }
            .task { page.load(URLRequest(url: url)) }
    }
}

private struct WebKitBrowser: View {
    let url: URL

    @State private var title = ""

    var body: some View {
        BrowserFrame(title: title) { WebKitPage(url: url, title: $title) }
    }
}

private struct WebKitPage: NSViewRepresentable {
    let url: URL
    @Binding var title: String

    func makeCoordinator() -> Coordinator { Coordinator(title: $title) }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let title: Binding<String>

        init(title: Binding<String>) {
            self.title = title
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            title.wrappedValue = web.title ?? ""
        }
    }
}
#endif
