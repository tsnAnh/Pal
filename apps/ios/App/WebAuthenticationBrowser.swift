import AuthenticationServices
import PalAuth

@MainActor
final class WebAuthenticationBrowser: NSObject, AuthorizationBrowser, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var finish: (() -> Void)?

    func present(_ url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                var resumed = false
                let complete: () -> Void = { [weak self] in
                    guard !resumed else { return }
                    resumed = true
                    self?.session = nil
                    self?.finish = nil
                    continuation.resume()
                }
                let session = ASWebAuthenticationSession(
                    url: url,
                    callback: .customScheme("dev.tsnanh.hermes.bot")
                ) { @Sendable [weak self] _, _ in
                    Task { @MainActor in self?.finish?() }
                }
                session.prefersEphemeralWebBrowserSession = true
                session.presentationContextProvider = self
                self.session = session
                self.finish = complete
                if !session.start() {
                    resumed = true
                    self.session = nil
                    self.finish = nil
                    continuation.resume(throwing: SignInError.browserUnavailable)
                }
            }
        } onCancel: {
            Task { @MainActor in self.dismissNow() }
        }
    }

    func dismiss() async {
        dismissNow()
    }

    private func dismissNow() {
        session?.cancel()
        finish?()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        PresentationAnchor.current()
    }
}
