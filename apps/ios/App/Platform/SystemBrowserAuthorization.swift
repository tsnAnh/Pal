import Foundation
import HermesAuth

struct SystemBrowserAuthorization: AuthorizationBrowser {
    private static let waitLimit: Duration = .seconds(600)

    func present(_ url: URL) async throws {
        guard await ExternalLink.open(url) else { throw SignInError.browserUnavailable }
        try await Task.sleep(for: Self.waitLimit)
    }

    func dismiss() async {}
}
