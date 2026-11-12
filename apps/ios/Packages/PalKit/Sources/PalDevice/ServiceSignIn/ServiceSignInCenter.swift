import Foundation
import PalProtocol
import Observation

public typealias SystemBrowserOpener = @MainActor @Sendable (URL) -> Void

public enum ServiceNativeOutcome: Sendable, Hashable {
    case signedIn
    case cancelled
    case failed(String)
}

public typealias ServiceNativeSignIn = @MainActor @Sendable (String) async -> ServiceNativeOutcome

public enum ServicePasteOutcome: Sendable, Hashable {
    case signedIn
    case tryAgain(String)
    case failed(String)
}

public struct ServicePasteSignIn: Sendable {
    public var begin: @MainActor @Sendable (String) async -> String?
    public var submit: @MainActor @Sendable (String, String) async -> ServicePasteOutcome
    public var cancel: @MainActor @Sendable (String) async -> Void
    public var reopen: @MainActor @Sendable (String) -> Void

    public init(
        begin: @escaping @MainActor @Sendable (String) async -> String?,
        submit: @escaping @MainActor @Sendable (String, String) async -> ServicePasteOutcome,
        cancel: @escaping @MainActor @Sendable (String) async -> Void,
        reopen: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.begin = begin
        self.submit = submit
        self.cancel = cancel
        self.reopen = reopen
    }
}

public enum ServiceSignInPhase: Sendable, Hashable {
    case prompting
    case signingIn
    case pasteAddress(String?)
    case keySet
    case keyFailed(String)
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
    public var requiresAppSignIn = false
    public var automaticSignInAvailable = false
    public var pasteSignInAvailable = false

    public var id: String { service }

    public var otherBotCount: Int { bots.filter { $0 != bot }.count }

    public var acceptsKey: Bool {
        switch phase {
        case .prompting, .keyFailed: true
        case .signingIn, .pasteAddress, .keySet, .signedIn, .failed, .expired: false
        }
    }

    public var takesKey: Bool { flow == .apiKey || flow == .header }

    public var canPasteInstead: Bool {
        guard requiresAppSignIn, pasteSignInAvailable else { return false }
        switch phase {
        case .failed: return true
        case .prompting, .signingIn, .pasteAddress, .keySet, .keyFailed, .signedIn, .expired: return false
        }
    }

    public var canSignIn: Bool {
        if requiresAppSignIn { return automaticSignInAvailable || pasteSignInAvailable }
        switch flow {
        case .deviceCode, .oauth: return true
        case .apiKey, .header, .manual, .unknown: return false
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
    @ObservationIgnored private let nativeSignIn: ServiceNativeSignIn?
    @ObservationIgnored private let pasteSignIn: ServicePasteSignIn?
    @ObservationIgnored private let dismissDelay: Duration
    @ObservationIgnored private var dismissals: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var nativeSignIns: [String: Task<ServiceNativeOutcome, Never>] = [:]

    public init(
        call: @escaping Call,
        openBrowser: @escaping SystemBrowserOpener,
        nativeSignIn: ServiceNativeSignIn? = nil,
        pasteSignIn: ServicePasteSignIn? = nil,
        dismissDelay: Duration = ServiceSignInCenter.signedInDismissDelay
    ) {
        self.call = call
        self.openBrowser = openBrowser
        self.nativeSignIn = nativeSignIn
        self.pasteSignIn = pasteSignIn
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
        if dialog.requiresAppSignIn {
            if dialog.automaticSignInAvailable {
                await signInNatively(service: service, requestID: requestID)
            } else {
                await startPasting(service: service, requestID: requestID)
            }
            return
        }
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
        case .apiKey, .header, .manual, .unknown:
            return
        }
    }

    public func signInByPasting() async {
        guard let dialog = current, dialog.canPasteInstead else { return }
        await startPasting(service: dialog.service, requestID: dialog.requestID)
    }

    public func reopenSignInPage() {
        guard let dialog = current, case .pasteAddress = dialog.phase else { return }
        pasteSignIn?.reopen(dialog.service)
    }

    public func submitAddress(_ text: String) async {
        guard let pasteSignIn, let dialog = current, case .pasteAddress = dialog.phase else { return }
        let service = dialog.service
        let requestID = dialog.requestID
        setPhase(.signingIn, for: service)
        let outcome = await pasteSignIn.submit(service, text)
        switch outcome {
        case .signedIn:
            guard isWaiting(service, requestID) else { return }
            setPhase(.signedIn, for: service)
            scheduleDismissal(of: service)
        case .tryAgain(let note):
            setPhase(.pasteAddress(note), for: service, ifRequest: requestID)
        case .failed(let text):
            setPhase(.failed(text), for: service, ifRequest: requestID)
        }
    }

    private func startPasting(service: String, requestID: String) async {
        guard let pasteSignIn else { return }
        setPhase(.signingIn, for: service)
        if let failure = await pasteSignIn.begin(service) {
            setPhase(.failed(failure), for: service, ifRequest: requestID)
        } else {
            setPhase(.pasteAddress(nil), for: service, ifRequest: requestID)
        }
    }

    private func signInNatively(service: String, requestID: String) async {
        guard let nativeSignIn else { return }
        setPhase(.signingIn, for: service)
        let attempt = Task { await nativeSignIn(service) }
        nativeSignIns[service] = attempt
        let outcome = await attempt.value
        nativeSignIns.removeValue(forKey: service)
        switch outcome {
        case .signedIn:
            guard isWaiting(service, requestID) else { return }
            setPhase(.signedIn, for: service)
            scheduleDismissal(of: service)
        case .cancelled:
            setPhase(.prompting, for: service, ifRequest: requestID)
        case .failed(let text):
            setPhase(.failed(text), for: service, ifRequest: requestID)
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
        nativeSignIns.removeValue(forKey: dialog.service)?.cancel()
        remove(service: dialog.service)
        await pasteSignIn?.cancel(dialog.service)
        switch dialog.phase {
        case .prompting, .signingIn, .pasteAddress, .keySet, .keyFailed:
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
                dialogs[index] = makeDialog(from: event)
            case .prompting, .signingIn, .pasteAddress, .keySet, .keyFailed:
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
            dialogs.append(makeDialog(from: event))
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

    private func makeDialog(from event: AuthRequiredEvent) -> ServiceSignInDialog {
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
            phase: .prompting,
            requiresAppSignIn: event.requiresAppSignIn,
            automaticSignInAvailable: nativeSignIn != nil,
            pasteSignInAvailable: pasteSignIn != nil
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
    static let didNotFinish = "Sign-in didn't finish."
    static let timedOut = "Sign-in took too long and was stopped."
}
