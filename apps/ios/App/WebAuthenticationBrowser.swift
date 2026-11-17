import AuthenticationServices
import Foundation
import PalAuth
import PalConnect

@MainActor
final class WebAuthenticationBrowser: NSObject, CallbackAuthorizationBrowser, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var finish: (() -> Void)?
    private var settle: ((Result<URL, any Error>) -> Void)?

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

    func authenticate(_ url: URL, callbackScheme: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                var resumed = false
                let settle: (Result<URL, any Error>) -> Void = { [weak self] result in
                    guard !resumed else { return }
                    resumed = true
                    self?.session = nil
                    self?.finish = nil
                    self?.settle = nil
                    continuation.resume(with: result)
                }
                let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { @Sendable [weak self] callback, error in
                    let result = webAuthenticationResult(callback, error)
                    Task { @MainActor in self?.settle?(result) }
                }
                session.prefersEphemeralWebBrowserSession = true
                session.presentationContextProvider = self
                self.session = session
                self.settle = settle
                self.finish = { settle(.failure(SignInError.cancelled)) }
                if !session.start() { settle(.failure(SignInError.browserUnavailable)) }
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

private func webAuthenticationResult(_ callback: URL?, _ error: (any Error)?) -> Result<URL, any Error> {
    if let callback { return .success(callback) }
    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return .failure(SignInError.cancelled) }
    return .failure(SignInError.browserUnavailable)
}
