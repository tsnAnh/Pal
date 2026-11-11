import Foundation
import HermesAuth

@MainActor
func openInSystemBrowser(_ url: URL) {
    SystemSettings.open(url)
}

struct SystemBrowserAuthorization: AuthorizationBrowser {
    private static let waitLimit: Duration = .seconds(600)

    func present(_ url: URL) async throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { throw SignInError.browserUnavailable }
        await openInSystemBrowser(url)
        try await Task.sleep(for: Self.waitLimit)
    }

    func dismiss() async {}
}
