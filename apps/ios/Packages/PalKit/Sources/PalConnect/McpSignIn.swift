import Foundation
import Observation
import PalProtocol

public enum McpSignInPhase: Sendable, Equatable {
    case inBrowser
    case pasteAddress
    case waitingForAdmin
    case signedIn
    case failed(SetupStatus)
    case dismissed
}

public enum McpSignInSteps {
    public static let flowID = "mcp-signin"
    public static let signInStepID = "signin"

    public static func waiting(vendor: String) -> (title: String, body: String) {
        (
            String(localized: "Waiting for you in the browser"),
            String(localized: "Sign in to \(vendor) and click Allow. You come back to Pal on your own.")
        )
    }

    public static func success(vendor: String) -> (title: String, body: String) {
        (String(localized: "\(vendor) is connected"), String(localized: "Pal can use your \(vendor) account when you ask."))
    }

    public static func admin(vendor: String) -> (title: String, body: String) {
        (
            String(localized: "Waiting for your admin"),
            String(localized: "\(vendor) needs an admin of your organisation to approve Pal. Come back and tap Connect again once your admin approved it.")
        )
    }

    public static let privateWindowHint = String(localized: "If the sign-in page skips the account choice, use a private window.")

    public static func steps(vendor: String) -> [FlowStep] {
        let waitCopy = Self.waiting(vendor: vendor)
        let doneCopy = Self.success(vendor: vendor)
        return [
            FlowStep(id: "open", title: String(localized: "Open the vendor"), kind: .instruction(openPage: nil)),
            FlowStep(
                id: signInStepID, title: String(localized: "Sign in"),
                kind: .browserRoundTrip(waitingTitle: waitCopy.title, waitingBody: waitCopy.body)
            ),
            FlowStep(id: "return", title: String(localized: "Back in Pal"), kind: .instruction(openPage: nil)),
            FlowStep(id: "done", title: String(localized: "Connected"), kind: .success(title: doneCopy.title, body: doneCopy.body)),
        ]
    }

    public static func engine(vendor: String) -> StepFlowEngine? {
        StepFlowEngine(
            flowID: flowID, steps: steps(vendor: vendor), resume: StepFlowProgress(flowID: flowID, stepID: signInStepID)
        )
    }
}

extension ConnectApp {
    public var usesMcpSignIn: Bool {
        switch source {
        case .mcp(_, let requires): requires.isEmpty
        case .catalog(let entry): entry.method == .mcpOAuth
        case .custom, .googleWorkspace: false
        }
    }
}

extension ConnectorPlatform {
    public var deviceName: String {
        switch self {
        case .mac: String(localized: "Mac")
        case .iPhone: String(localized: "iPhone")
        case .iPad: String(localized: "iPad")
        }
    }
}

extension McpOAuthError {
    public var code: String {
        switch self {
        case .discoveryFailed: "discovery_failed"
        case .registrationFailed: "invalid_client_metadata"
        case .browserUnavailable: "browser_unavailable"
        case .cancelled: "cancelled"
        case .timedOut: "sign_in_timed_out"
        case .listenerFailed: "listener_failed"
        case .denied: "access_denied"
        case .stateMismatch: "state_mismatch"
        case .tokenExchangeFailed: "token_exchange_failed"
        case .randomnessUnavailable: "internal"
        case .rejectedByGateway: "gateway_rejected"
        case .serverAddFailed: "server_add_failed"
        case .gatewayUnavailable: "offline"
        case .handshakeUsed: "handshake_used"
        case .pasted: "sign_in_failed"
        }
    }
}

public enum McpSignInResolution: Sendable, Equatable {
    case dismissed
    case waitingForAdmin
    case failed(SetupStatus)
}

public enum McpSignInStatus {
    private static let fixedErrors: [McpOAuthError] = [
        .discoveryFailed, .registrationFailed, .browserUnavailable, .cancelled, .timedOut, .listenerFailed, .denied,
        .stateMismatch, .tokenExchangeFailed, .randomnessUnavailable, .gatewayUnavailable, .handshakeUsed,
    ]

    static func code(forReason reason: String) -> String {
        if let failure = McpSignInFailure.allCases.first(where: { $0.reason == reason }) { return failure.code }
        if let known = fixedErrors.first(where: { $0.reason == reason }) { return known.code }
        return "sign_in_failed"
    }

    public static func resolve(_ error: any Error, vendor: String, platform: ConnectorPlatform) -> McpSignInResolution {
        if error is CancellationError { return .dismissed }
        let device = platform.deviceName
        guard let known = error as? ConnectAppsError else {
            return .failed(SetupStatus(code: SetupStatusClass.internalFault.rawValue, subject: vendor, device: device))
        }
        switch known {
        case .cancelled: return .dismissed
        case .adminApprovalPending: return .waitingForAdmin
        case .signInRefused(let failure, let fault): return refused(failure, fault, vendor: vendor, device: device)
        case .faulted(let fault): return .failed(SetupStatus(fault: fault, subject: vendor, device: device))
        case .signInFailed(let reason): return plain(reason, vendor: vendor, device: device)
        case .accountName(let problem):
            return .failed(SetupStatus(code: "account_name", subject: vendor, device: device, detail: problem.message))
        case .failed: return .failed(SetupStatus(code: "offline", subject: vendor, device: device))
        case .unavailable, .credentialsRequired, .oauthClient:
            return .failed(SetupStatus(code: SetupStatusClass.internalFault.rawValue, subject: vendor, device: device))
        }
    }

    private static func refused(_ failure: McpSignInFailure, _ fault: GatewayFault, vendor: String, device: String) -> McpSignInResolution {
        let gatewayCode = SetupStatusClass.byCode[fault.reason.lowercased()] == nil ? failure.code : fault.reason
        return .failed(SetupStatus(
            code: gatewayCode, method: fault.method, trace: fault.trace.rawValue, gatewayVersion: fault.gatewayVersion,
            subject: vendor, device: device, detail: failure.reason
        ))
    }

    private static func plain(_ reason: String, vendor: String, device: String) -> McpSignInResolution {
        if reason == McpOAuthError.cancelled.reason { return .dismissed }
        return .failed(SetupStatus(code: code(forReason: reason), subject: vendor, device: device, detail: reason))
    }
}

public enum McpPasteShape: Sendable, Equatable {
    case empty
    case notAnAddress
    case missingCode
    case valid

    public static func of(_ text: String) -> McpPasteShape {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        guard let parts = URLComponents(string: trimmed), let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parts.host?.isEmpty == false
        else { return .notAnAddress }
        let names = (parts.queryItems ?? []).map(\.name)
        return names.contains("code") || names.contains("error") ? .valid : .missingCode
    }

    public var message: String? {
        switch self {
        case .empty: nil
        case .valid: String(localized: "Looks right")
        case .notAnAddress: String(localized: "That is not a web address. Copy the address from your browser's address bar.")
        case .missingCode:
            String(localized: "That address has no sign-in code. Copy it after you approve, from the page that fails to load.")
        }
    }
}

@MainActor
@Observable
public final class McpSignInController: Identifiable {
    public let app: ConnectApp
    public let id: String
    public let platform: ConnectorPlatform
    public let account: ConnectorAccountTarget?
    public private(set) var phase: McpSignInPhase = .inBrowser
    public private(set) var privateWindowHint: String?
    public private(set) var pasteProblem: String?
    public private(set) var isSubmitting = false

    @ObservationIgnored private let service: ConnectAppsService
    @ObservationIgnored private let openLink: @MainActor (URL) -> Bool
    @ObservationIgnored private let finished: @MainActor () async -> Void
    @ObservationIgnored private var pasteSession: (any McpPasteSigning)?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    public init(
        app: ConnectApp, service: ConnectAppsService, platform: ConnectorPlatform, account: ConnectorAccountTarget? = nil,
        openLink: @escaping @MainActor (URL) -> Bool, finished: @escaping @MainActor () async -> Void
    ) {
        self.app = app
        id = app.id
        self.service = service
        self.platform = platform
        self.account = account
        self.openLink = openLink
        self.finished = finished
    }

    public var vendor: String { app.name }

    public var engine: StepFlowEngine? { McpSignInSteps.engine(vendor: app.name) }

    public func start() async {
        guard !started else { return }
        started = true
        await execute()
    }

    public func retry() async {
        guard case .failed = phase else { return }
        phase = .inBrowser
        await execute()
    }

    public func submit(_ address: String) async {
        guard phase == .pasteAddress, !isSubmitting, let session = pasteSession, McpPasteShape.of(address) == .valid else { return }
        isSubmitting = true
        pasteProblem = nil
        let outcome = await session.submit(address)
        isSubmitting = false
        switch outcome {
        case .signedIn:
            pasteSession = nil
            await succeed()
        case .tryAgain(let note):
            pasteProblem = note
        case .failed(let reason):
            pasteSession = nil
            resolve(ConnectAppsError.signInFailed(reason))
        case .adminApprovalPending:
            pasteSession = nil
            resolve(ConnectAppsError.adminApprovalPending)
        }
    }

    public func reopen() {
        guard let url = pasteSession?.authorizeURL else { return }
        _ = openLink(url)
    }

    public func cancel() async {
        runTask?.cancel()
        let session = pasteSession
        pasteSession = nil
        if phase != .signedIn { phase = .dismissed }
        await session?.cancel()
    }

    private func execute() async {
        pasteProblem = nil
        privateWindowHint = nil
        let task = Task { @MainActor [self] in await run() }
        runTask = task
        await task.value
        runTask = nil
    }

    private func run() async {
        do {
            if app.requiresAppSignIn { try await signInUpwork() } else { try await signInPreset() }
        } catch {
            resolve(error)
        }
    }

    private func signInPreset() async throws {
        let outcome = try await service.signInMcp(app, platform: platform, account: account) { [weak self] hint in
            await self?.noteStart(privateWindowHint: hint)
        }
        switch outcome {
        case .connected: await succeed()
        case .paste(let session): try await offerPaste(session)
        }
    }

    private func signInUpwork() async throws {
        noteStart(privateWindowHint: account?.selectsAccount == true)
        if platform.returnsAutomatically {
            try await service.connectUpwork(app, account: account)
            await succeed()
        } else {
            try await offerPaste(try await service.beginUpworkPaste(app, account: account))
        }
    }

    private func noteStart(privateWindowHint hint: Bool) {
        privateWindowHint = hint ? McpSignInSteps.privateWindowHint : nil
    }

    private func offerPaste(_ session: any McpPasteSigning) async throws {
        guard openLink(session.authorizeURL) else {
            await session.cancel()
            throw ConnectAppsError.signInFailed(McpOAuthError.browserUnavailable.reason)
        }
        pasteSession = session
        phase = .pasteAddress
    }

    private func succeed() async {
        guard phase != .dismissed else { return }
        phase = .signedIn
        await finished()
    }

    private func resolve(_ error: any Error) {
        guard phase != .dismissed else { return }
        switch McpSignInStatus.resolve(error, vendor: app.name, platform: platform) {
        case .dismissed: phase = .dismissed
        case .waitingForAdmin: phase = .waitingForAdmin
        case .failed(let status): phase = .failed(status)
        }
    }
}
