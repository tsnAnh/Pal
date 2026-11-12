import Foundation
import PalProtocol
import Observation

public typealias SystemBrowserOpener = @MainActor @Sendable (URL) -> Void

public enum ServiceSignInPhase: Sendable, Hashable {
    case prompting
    case signingIn
    case keySet
    case keyFailed(String)
    case callbackFailed(String)
    case signedIn
    case failed(String)
    case expired
}

public struct ServiceSignInDialog: Sendable, Hashable, Identifiable {
    public var requestID: String
    public var service: String
    public var serviceName: String
    public var bot: String
    public var bots: [String]
    public var reason: ServiceSignInReason
    public var flow: ServiceSignInFlow
    public var userCode: String?
    public var verificationURI: String?
    public var server: String?
    public var phase: ServiceSignInPhase

    public var id: String { service }

    public var otherBotCount: Int { bots.filter { $0 != bot }.count }

    public var acceptsKey: Bool {
        switch phase {
        case .prompting, .keyFailed: true
        case .signingIn, .keySet, .callbackFailed, .signedIn, .failed, .expired: false
        }
    }

    public var takesKey: Bool { flow == .apiKey || flow == .header }

    public var canSignIn: Bool {
        switch flow {
        case .deviceCode, .oauth, .oauthPaste: true
        case .apiKey, .header, .manual, .unknown: false
        }
    }
}

public struct ServiceSignInResolution: Sendable, Hashable {
    public var sequence: Int
    public var requestID: String
    public var service: String?
    public var outcome: ServiceSignInOutcome
    public var reason: String?
}

@MainActor
@Observable
public final class ServiceSignInCenter {
    public typealias Call = @Sendable (String, JSONValue?) async throws -> JSONValue

    public static let signedInDismissDelay = Duration.milliseconds(1500)

    public private(set) var dialogs: [ServiceSignInDialog] = []
    public private(set) var lastResolution: ServiceSignInResolution?

    public var current: ServiceSignInDialog? { dialogs.first }

    @ObservationIgnored private let call: Call
    @ObservationIgnored private let openBrowser: SystemBrowserOpener
    @ObservationIgnored private let dismissDelay: Duration
    @ObservationIgnored private var dismissals: [String: Task<Void, Never>] = [:]

    public init(
        call: @escaping Call,
        openBrowser: @escaping SystemBrowserOpener,
        dismissDelay: Duration = ServiceSignInCenter.signedInDismissDelay
    ) {
        self.call = call
        self.openBrowser = openBrowser
        self.dismissDelay = dismissDelay
    }

    public func receive(_ event: GatewayEvent) {
        if let required = AuthRequiredEvent(event: event) {
            apply(required)
        } else if let resolved = AuthResolvedEvent(event: event) {
            apply(resolved)
        }
    }

    public func signIn() async {
        guard let dialog = current, dialog.phase == .prompting, dialog.canSignIn else { return }
        let requestID = dialog.requestID
        let service = dialog.service
        switch dialog.flow {
        case .deviceCode:
            guard let url = Self.secureURL(dialog.verificationURI) else {
                setPhase(.failed(Self.pageFailure), for: service)
                return
            }
            setPhase(.signingIn, for: service)
            openBrowser(url)
            do {
                _ = try await call(ServiceSignInWire.signInMethod, ServiceSignInWire.requestParams(requestID))
            } catch {
                setPhase(.failed(Self.startFailure), for: service, ifRequest: requestID)
            }
        case .oauth:
            setPhase(.signingIn, for: service)
            do {
                let result = AuthSignInResult(try await call(ServiceSignInWire.signInMethod, ServiceSignInWire.requestParams(requestID)))
                guard result.recorded, let url = Self.secureURL(result.authorizationURL) else {
                    setPhase(.failed(Self.startFailure), for: service, ifRequest: requestID)
                    return
                }
                guard isWaiting(service, requestID) else { return }
                openBrowser(url)
            } catch {
                setPhase(.failed(Self.startFailure), for: service, ifRequest: requestID)
            }
        case .oauthPaste:
            guard let url = Self.secureURL(dialog.verificationURI) else {
                setPhase(.failed(Self.pageFailure), for: service)
                return
            }
            setPhase(.signingIn, for: service)
            openBrowser(url)
            do {
                _ = try await call(ServiceSignInWire.signInMethod, ServiceSignInWire.requestParams(requestID))
            } catch {
                setPhase(.failed(Self.startFailure), for: service, ifRequest: requestID)
            }
        case .apiKey, .header, .manual, .unknown:
            return
        }
    }

    public func submitCallback(_ text: String) async {
        guard let dialog = current, dialog.flow == .oauthPaste, let pasted = PastedCallback(text) else { return }
        switch dialog.phase {
        case .signingIn, .callbackFailed: break
        case .prompting, .keySet, .keyFailed, .signedIn, .failed, .expired: return
        }
        let requestID = dialog.requestID
        let service = dialog.service
        setPhase(.signingIn, for: service)
        do {
            let params = ServiceSignInWire.submitCallbackParams(requestID: requestID, value: pasted.value)
            let result = AuthCallbackResult(try await call(ServiceSignInWire.submitCallbackMethod, params))
            switch result.outcome {
            case .stored: break
            case .failed, .unknown: setPhase(.callbackFailed(result.reason ?? Self.callbackFailure), for: service, ifRequest: requestID)
            case .rejected: setPhase(.expired, for: service, ifRequest: requestID)
            }
        } catch {
            setPhase(.callbackFailed(Self.callbackFailure), for: service, ifRequest: requestID)
        }
    }

    public func submitCredential(_ secret: SecretString) async {
        guard let dialog = current, dialog.takesKey, dialog.acceptsKey, !secret.isEmpty else { return }
        let requestID = dialog.requestID
        let service = dialog.service
        setPhase(.signingIn, for: service)
        do {
            let params = ServiceSignInWire.submitCredentialParams(requestID: requestID, value: secret)
            let outcome = AuthCredentialOutcome(try await call(ServiceSignInWire.submitCredentialMethod, params))
            switch outcome {
            case .stored: setPhase(.keySet, for: service, ifRequest: requestID)
            case .failed, .unknown: setPhase(.keyFailed(Self.keyFailure), for: service, ifRequest: requestID)
            case .rejected: setPhase(.expired, for: service, ifRequest: requestID)
            }
        } catch {
            setPhase(.keyFailed(Self.keyFailure), for: service, ifRequest: requestID)
        }
    }

    public func notNow() async {
        guard let dialog = current else { return }
        remove(service: dialog.service)
        switch dialog.phase {
        case .prompting, .signingIn, .keySet, .keyFailed, .callbackFailed:
            _ = try? await call(ServiceSignInWire.declineMethod, ServiceSignInWire.requestParams(dialog.requestID))
        case .signedIn, .failed, .expired:
            return
        }
    }

    private func apply(_ event: AuthRequiredEvent) {
        if let index = dialogs.firstIndex(where: { $0.service == event.service }) {
            var dialog = dialogs[index]
            switch dialog.phase {
            case .signedIn, .failed, .expired:
                dismissals.removeValue(forKey: event.service)?.cancel()
                dialogs[index] = Self.dialog(from: event)
            case .prompting, .signingIn, .keySet, .keyFailed, .callbackFailed:
                dialog.requestID = event.requestID
                dialog.serviceName = event.serviceName
                dialog.bot = event.bot
                dialog.bots = Self.merged(dialog.bots, event.bots)
                dialog.reason = event.reason
                if event.userCode != nil { dialog.userCode = event.userCode }
                if event.verificationURI != nil { dialog.verificationURI = event.verificationURI }
                if event.server != nil { dialog.server = event.server }
                dialogs[index] = dialog
            }
        } else {
            dialogs.append(Self.dialog(from: event))
        }
    }

    private func apply(_ event: AuthResolvedEvent) {
        let dialog = dialogs.first(where: { $0.requestID == event.requestID })
        lastResolution = ServiceSignInResolution(
            sequence: (lastResolution?.sequence ?? 0) + 1, requestID: event.requestID, service: dialog?.service,
            outcome: event.outcome, reason: event.reason
        )
        guard let dialog else { return }
        switch event.outcome {
        case .signedIn:
            setPhase(.signedIn, for: dialog.service)
            scheduleDismissal(of: dialog.service)
        case .declined:
            remove(service: dialog.service)
        case .failed, .unknown:
            setPhase(.failed(event.reason ?? Self.didNotFinish), for: dialog.service)
        case .timedOut:
            setPhase(dialog.takesKey ? .expired : .failed(Self.timedOut), for: dialog.service)
        }
    }

    private func scheduleDismissal(of service: String) {
        dismissals[service]?.cancel()
        let delay = dismissDelay
        dismissals[service] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismissSignedIn(service)
        }
    }

    private func dismissSignedIn(_ service: String) {
        guard let dialog = dialogs.first(where: { $0.service == service }), dialog.phase == .signedIn else { return }
        remove(service: service)
    }

    private func remove(service: String) {
        dismissals.removeValue(forKey: service)?.cancel()
        dialogs.removeAll { $0.service == service }
    }

    private func isWaiting(_ service: String, _ requestID: String) -> Bool {
        dialogs.first(where: { $0.service == service })?.phase == .signingIn
    }

    private func setPhase(_ phase: ServiceSignInPhase, for service: String, ifRequest requestID: String? = nil) {
        guard let index = dialogs.firstIndex(where: { $0.service == service }) else { return }
        if let requestID, dialogs[index].requestID != requestID { return }
        if requestID != nil, dialogs[index].phase != .signingIn { return }
        dialogs[index].phase = phase
    }

    private static func dialog(from event: AuthRequiredEvent) -> ServiceSignInDialog {
        ServiceSignInDialog(
            requestID: event.requestID,
            service: event.service,
            serviceName: event.serviceName,
            bot: event.bot,
            bots: event.bots,
            reason: event.reason,
            flow: event.flow,
            userCode: event.userCode,
            verificationURI: event.verificationURI,
            server: event.server,
            phase: .prompting
        )
    }

    private static func merged(_ existing: [String], _ incoming: [String]) -> [String] {
        var seen = Set<String>()
        return (existing + incoming).filter { seen.insert($0).inserted }
    }

    private static func secureURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host()?.isEmpty == false else { return nil }
        return url
    }

    static let pageFailure = "We couldn't open the sign-in page."
    static let startFailure = "We couldn't start sign-in. Please try again later."
    static let keyFailure = "Couldn't save that. Check it and try again."
    public static let callbackFailure = "That address didn't work. Copy it again from the browser and try again."
    static let didNotFinish = "Sign-in didn't finish."
    static let timedOut = "Sign-in took too long and was stopped."
}
