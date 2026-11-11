import Foundation
import HermesBotProfile
import Observation

@MainActor
@Observable
final class WhatsAppModel {
    enum Phase: Equatable {
        case loading
        case ready(WhatsAppStatus)
        case busy(Activity)
        case unavailable
    }

    enum Activity: Equatable {
        case saving
        case unpairing
        case checking
    }

    private(set) var phase: Phase = .loading
    private(set) var pairing: WhatsAppPairingState = .idle
    private(set) var notice: String?
    var mode: WhatsAppMode = .selfChat
    var allowedUsers = ""
    var confirmsUnpair = false

    let botName: String
    let displayName: String
    private let services: BotsServices
    private var polling: Task<Void, Never>?
    private var generation = 0
    private var appliedPairingID: String?

    static let pollInterval: Duration = .seconds(2)
    static let pollFailureLimit = 4
    private static let restartNotice = String(localized: "Pal needs a restart to finish this. It can't restart while a chat is running.")

    init(botName: String, displayName: String, services: BotsServices) {
        self.botName = botName
        self.displayName = displayName
        self.services = services
    }

    var status: WhatsAppStatus? {
        if case .ready(let status) = phase { status } else { nil }
    }

    var isPaired: Bool { status?.isPaired == true }

    var normalizedAllowedUsers: String? { WhatsAppAllowedUsers.normalized(allowedUsers) }

    var canPair: Bool { status != nil && !pairing.isActive && normalizedAllowedUsers != nil }

    var hasUnsavedSettings: Bool {
        guard let status, status.isPaired, let normalized = normalizedAllowedUsers else { return false }
        return mode != status.mode || normalized != status.allowedUsers
    }

    func load() async {
        guard case .loading = phase else { return }
        await refresh()
    }

    func refresh() async {
        do {
            let status = try await services.whatsApp.status(profile: botName)
            adopt(status)
        } catch is CancellationError {
        } catch {
            phase = .unavailable
        }
    }

    func recheck() async {
        phase = .busy(.checking)
        notice = nil
        await refresh()
    }

    func startPairing(reset: Bool) async {
        guard canPair, let allowed = normalizedAllowedUsers else { return }
        notice = nil
        appliedPairingID = nil
        generation += 1
        let token = generation
        pairing = WhatsAppPairingMachine.reduce(pairing, .startRequested)
        do {
            let result = try await services.whatsApp.startPairing(profile: botName, mode: mode, allowedUsers: allowed, resetSession: reset)
            guard token == generation else {
                await release(result.pairingID)
                return
            }
            await absorb(result)
            if pairing.isActive { beginPolling(token: token) }
        } catch is CancellationError {
        } catch {
            guard token == generation else { return }
            pairing = WhatsAppPairingMachine.reduce(pairing, .requestFailed(WhatsAppFailure(error)))
        }
    }

    func cancelPairing() async {
        let id = pairing.pairingID
        invalidate()
        pairing = WhatsAppPairingMachine.reduce(pairing, .cancelled)
        if let id { await release(id) }
    }

    func leaveForeground() {
        let id = pairing.pairingID
        invalidate()
        pairing = WhatsAppPairingMachine.reduce(pairing, .leftForeground)
        if let id { Task { [services, botName] in try? await services.whatsApp.cancelPairing(profile: botName, pairingID: id) } }
    }

    func dismissOutcome() {
        guard !pairing.isActive else { return }
        pairing = .idle
    }

    func saveSettings() async {
        guard let allowed = normalizedAllowedUsers else { return }
        phase = .busy(.saving)
        notice = nil
        do {
            adopt(try await services.whatsApp.configure(profile: botName, mode: mode, allowedUsers: allowed))
            reportReload()
        } catch is CancellationError {
        } catch {
            await restoreAfterFailure(String(localized: "Couldn't save your changes. Try again."))
        }
    }

    func unpair() async {
        confirmsUnpair = false
        phase = .busy(.unpairing)
        notice = nil
        do {
            adopt(try await services.whatsApp.unpair(profile: botName))
            reportReload()
        } catch is CancellationError {
        } catch {
            await restoreAfterFailure(String(localized: "Couldn't unpair WhatsApp. Try again."))
        }
    }

    private func adopt(_ status: WhatsAppStatus) {
        phase = .ready(status)
        if !pairing.isActive {
            mode = status.mode ?? mode
            allowedUsers = status.allowedUsers
        }
    }

    private func restoreAfterFailure(_ message: String) async {
        await refresh()
        notice = message
    }

    private func reportReload() {
        guard let reload = status?.reload, reload.needsAttention else { return }
        notice = Self.restartNotice
    }

    private func invalidate() {
        generation += 1
        polling?.cancel()
        polling = nil
    }

    private func release(_ id: String) async {
        try? await services.whatsApp.cancelPairing(profile: botName, pairingID: id)
    }

    private func beginPolling(token: Int) {
        polling?.cancel()
        polling = Task { [weak self] in
            var failures = 0
            while let self, !Task.isCancelled, token == generation, pairing.isActive, let id = pairing.pairingID {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, token == generation else { return }
                do {
                    let result = try await services.whatsApp.pairingStatus(profile: botName, pairingID: id)
                    guard token == generation else { return }
                    failures = 0
                    await absorb(result)
                } catch is CancellationError {
                    return
                } catch BotsError.notFound {
                    guard token == generation else { return }
                    pairing = WhatsAppPairingMachine.reduce(pairing, .pairingGone)
                } catch {
                    failures += 1
                    guard failures >= Self.pollFailureLimit, token == generation else { continue }
                    let id = pairing.pairingID
                    pairing = WhatsAppPairingMachine.reduce(pairing, .requestFailed(.unavailable))
                    if let id { await release(id) }
                }
            }
        }
    }

    private func absorb(_ result: WhatsAppPairingWire) async {
        let before = pairing
        pairing = WhatsAppPairingMachine.reduce(before, .polled(result))
        guard case .connected(let id, _) = pairing, appliedPairingID != id else { return }
        appliedPairingID = id
        await finishPairing(id)
    }

    private func finishPairing(_ id: String) async {
        guard let allowed = normalizedAllowedUsers else { return }
        do {
            let reload = try await services.whatsApp.applyPairing(profile: botName, pairingID: id, mode: mode, allowedUsers: allowed)
            await refresh()
            if reload.needsAttention { notice = Self.restartNotice }
        } catch is CancellationError {
        } catch {
            pairing = .failed(.unavailable)
        }
    }
}
