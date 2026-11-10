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

    @Environment(\.dismiss) private var dismiss
    @State private var page = WebPage()

    var body: some View {
        NavigationStack {
            WebView(page)
                .navigationTitle(page.title)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("browserDone")
                    }
                }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 560, idealHeight: 720)
        .task { page.load(URLRequest(url: url)) }
    }
}
#endif
