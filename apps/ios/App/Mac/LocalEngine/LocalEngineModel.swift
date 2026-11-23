#if os(macOS)
import Foundation
import Observation
import PalDiagnostics
import PalLocalEngine
import PalREST

enum TailnetState: Equatable {
    case off
    case on(url: String, username: String, reachable: Bool?)
}

@MainActor
@Observable
final class LocalEngineModel {
    private(set) var state: LocalEngineState = .detecting
    private(set) var installStartedAt: Date?
    private(set) var startAtLogin: Bool?
    private(set) var isUpdatingLogin = false
    private(set) var isSigningIn = false
    private(set) var settingsFailure: EngineFailure?
    private(set) var tailnet: TailnetState?
    private(set) var tailnetPassword: String?
    private(set) var tailnetFailure: String?
    private(set) var isUpdatingTailnet = false
    var isPresentingSetup = false

    @ObservationIgnored private weak var connection: ConnectionModel?
    @ObservationIgnored private let service: LocalEngineService
    @ObservationIgnored private let diagnostics: Diagnostics
    @ObservationIgnored private var session: EngineSession?
    @ObservationIgnored private var installTask: Task<Void, Never>?

    init(connection: ConnectionModel, diagnostics: Diagnostics, service: LocalEngineService? = nil) {
        self.connection = connection
        self.diagnostics = diagnostics
        self.service = service ?? Self.makeService(diagnostics: diagnostics)
    }

    private static func makeService(diagnostics: Diagnostics) -> LocalEngineService {
        var configuration = LocalEngineConfiguration.standard()
        #if DEBUG
        configuration = LocalEngineOverrides.configuration(arguments: ProcessInfo.processInfo.arguments, base: configuration)
        #endif
        return LocalEngineService(
            configuration: configuration,
            installer: Bundle.main.url(forResource: "install", withExtension: "sh"),
            runner: PosixEngineProcessRunner(),
            probe: HTTPEngineProbe(transport: URLSessionHTTPTransport()),
            log: FileEngineLog(url: configuration.installLog)
        )
    }

    var isInstalling: Bool {
        if case .installing = state { true } else { false }
    }

    var isRunningForSignIn: Bool { state == .ready && session != nil }

    func detect() async {
        switch state {
        case .installing, .removing: return
        default: break
        }
        let result = await service.detect()
        session = result.session
        state.apply(.detected(result.detection))
    }

    func presentSetup() {
        guard !isInstalling else {
            isPresentingSetup = true
            return
        }
        isPresentingSetup = true
    }

    func dismissSetup() {
        guard !isInstalling, !isSigningIn else { return }
        isPresentingSetup = false
        if case .failed = state { Task { await detect() } }
    }

    func install() {
        guard installTask == nil, !state.isBusy, !isSigningIn else { return }
        let resume = state.failure?.resumeStage
        installStartedAt = Date()
        let (events, continuation) = AsyncStream<LocalEngineEvent>.makeStream()
        let service = service
        installTask = Task { [weak self] in
            let consumer = Task { [weak self] in
                for await event in events { self?.state.apply(event) }
            }
            do {
                let session = try await service.install(resumingFrom: resume) { continuation.yield($0) }
                continuation.finish()
                await consumer.value
                await self?.installSucceeded(session)
            } catch is CancellationError {
                continuation.finish()
                await consumer.value
                await self?.installCancelled()
            } catch {
                continuation.finish()
                await consumer.value
                self?.installFailed(error)
            }
            self?.installTask = nil
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    func continueWithRunningEngine() async {
        guard let session, !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        _ = await connection?.signInToLocalEngine(session, announcingOwnerIntro: false)
    }

    func startIfStopped() async {
        do {
            session = try await service.startIfStopped() ?? session
        } catch {
            diagnostics.info("engine", "start before connecting failed: \(Diagnostics.describe(error))")
        }
    }

    func refreshSettings() async {
        await detect()
        if let status = try? await service.serviceStatus() { startAtLogin = status.startOnLogin }
        await refreshTailnet()
    }

    private func refreshTailnet() async {
        guard !isUpdatingTailnet, let status = try? await service.tailnetStatus(), !isUpdatingTailnet else { return }
        apply(status)
    }

    private func apply(_ status: TailnetStatus) {
        if status.enabled, let url = status.url, let username = status.username {
            tailnet = .on(url: url, username: username, reachable: status.reachable)
        } else {
            tailnet = .off
            tailnetPassword = nil
        }
    }

    func enableTailnet() async {
        guard !isUpdatingTailnet else { return }
        isUpdatingTailnet = true
        tailnetFailure = nil
        defer { isUpdatingTailnet = false }
        do {
            let credentials = try await service.enableTailnet()
            tailnet = .on(url: credentials.url, username: credentials.username, reachable: credentials.reachable)
            tailnetPassword = credentials.password
        } catch {
            tailnetFailure = tailnetMessage(for: error)
        }
    }

    func disableTailnet() async {
        guard !isUpdatingTailnet else { return }
        isUpdatingTailnet = true
        tailnetFailure = nil
        defer { isUpdatingTailnet = false }
        do {
            apply(try await service.disableTailnet())
        } catch {
            tailnetFailure = tailnetMessage(for: error)
        }
    }

    func dismissTailnetPassword() {
        tailnetPassword = nil
    }

    private func tailnetMessage(for error: any Error) -> String {
        switch error {
        case let error as TailnetError: return error.message
        case let failure as EngineFailure: return failure.reason
        default:
            diagnostics.info("engine", "tailnet change failed: \(Diagnostics.describe(error))")
            return EngineFailure.unexpected(trace: EngineFailure.makeTrace()).reason
        }
    }

    func setStartAtLogin(_ enabled: Bool) async {
        guard !isUpdatingLogin else { return }
        isUpdatingLogin = true
        settingsFailure = nil
        defer { isUpdatingLogin = false }
        do {
            startAtLogin = try await service.setStartAtLogin(enabled).startOnLogin
        } catch let failure as EngineFailure {
            settingsFailure = failure
        } catch {
            diagnostics.info("engine", "start at login failed: \(Diagnostics.describe(error))")
            settingsFailure = .unexpected(trace: EngineFailure.makeTrace())
        }
    }

    func remove(deleteData: Bool) async {
        guard !state.isBusy else { return }
        state.apply(.removalBegan)
        guard state == .removing else { return }
        settingsFailure = nil
        do {
            try await service.remove(deleteData: deleteData)
            state.apply(.removalSucceeded)
            session = nil
            startAtLogin = nil
            tailnet = nil
            tailnetPassword = nil
            await connection?.signOut()
        } catch let failure as EngineFailure {
            state.apply(.removalFailed(failure))
            settingsFailure = failure
        } catch {
            diagnostics.info("engine", "remove failed: \(Diagnostics.describe(error))")
            let failure = EngineFailure.removalFailed(trace: EngineFailure.makeTrace())
            state.apply(.removalFailed(failure))
            settingsFailure = failure
        }
    }

    private func installSucceeded(_ session: EngineSession) async {
        self.session = session
        state.apply(.installSucceeded)
        isSigningIn = true
        let signedIn = await connection?.signInToLocalEngine(session, announcingOwnerIntro: true) ?? false
        isSigningIn = false
        if signedIn {
            isPresentingSetup = false
        } else {
            state.apply(.startFailed(.signInFailed(trace: EngineFailure.makeTrace())))
        }
    }

    private func installCancelled() async {
        let result = await service.detect()
        session = result.session
        state.apply(.installCancelled(result.detection))
        isPresentingSetup = false
    }

    private func installFailed(_ error: any Error) {
        let failure = (error as? EngineFailure) ?? {
            diagnostics.info("engine", "install failed unexpectedly: \(Diagnostics.describe(error))")
            return EngineFailure.unexpected(trace: EngineFailure.makeTrace())
        }()
        state.apply(.installFailed(failure))
    }
}
#endif
