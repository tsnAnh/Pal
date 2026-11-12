import Foundation
import Observation
import PalBotProfile

@MainActor
@Observable
final class HostUpdateModel {
    private(set) var check: HostUpdateCheck?
    private(set) var checking = false
    private(set) var checkFailed = false
    private(set) var progress: HostUpdateProgress?
    private(set) var notice: String?
    var showingProgress = false
    var confirmingTurns = false

    private let client: HostUpdateClient
    private var following = false

    init(client: HostUpdateClient) {
        self.client = client
    }

    var isUpdating: Bool { following }

    func load() async {
        if let stored = await client.result() {
            switch stored {
            case .running: await follow()
            case .succeeded, .failed: progress = stored
            default: break
            }
        }
        await refreshCheck()
    }

    func refreshCheck() async {
        guard !checking, !following else { return }
        checking = true
        defer { checking = false }
        do {
            check = try await client.check()
            checkFailed = false
        } catch is CancellationError {
        } catch {
            checkFailed = true
        }
    }

    func requestUpdate() async {
        guard let check, check.canUpdate, !following else { return }
        if check.turnIsRunning {
            confirmingTurns = true
            return
        }
        await start(confirmTurns: false)
    }

    func start(confirmTurns: Bool) async {
        guard !following else { return }
        notice = nil
        switch await client.start(confirmTurns: confirmTurns) {
        case .started, .alreadyRunning: await follow()
        case .refused(let blockers): handleRefusal(blockers)
        case .failed: notice = String(localized: "Pal couldn't start the update. Nothing was changed.")
        }
    }

    func dismissProgress() {
        showingProgress = false
        if progress?.isFinal == true {
            progress = nil
            Task { await refreshCheck() }
        }
    }

    private func handleRefusal(_ blockers: [HostUpdateBlocker]) {
        if blockers.contains(.turnRunning) && blockers.count == 1 {
            confirmingTurns = true
        } else if blockers.contains(.updateRunning) {
            notice = String(localized: "Another update is already running on this computer.")
        } else if blockers.contains(.dirtyInstall) {
            notice = String(localized: "This copy of Pal has local changes, so it can't update itself.")
        } else {
            notice = String(localized: "Pal can't update right now.")
        }
    }

    private func follow() async {
        following = true
        showingProgress = true
        progress = .running(phase: .preparing, tail: [])
        let final = await client.follow { [weak self] update in
            Task { @MainActor in self?.progress = update }
        }
        progress = final
        following = false
    }

    static func failureText(_ failure: HostUpdateFailure) -> String {
        switch failure {
        case .noNetwork:
            String(localized: "Pal couldn't reach the internet to download the update. Your current version is still running.")
        case .failed(_, let oldVersionRunning):
            oldVersionRunning
                ? String(localized: "The update didn't finish. Your current version is still running.")
                : String(localized: "The update didn't finish.")
        case .needsRecovery:
            String(localized: "The update stopped part-way and Pal's files need repair. Pal repairs them the next time it starts.")
        case .interrupted: String(localized: "The update was interrupted. Check the version below, then try again.")
        case .notStarted: String(localized: "Pal couldn't start the update. Nothing was changed.")
        }
    }

    static func phaseTitle(_ phase: HostUpdatePhase) -> String {
        switch phase {
        case .preparing: String(localized: "Getting ready")
        case .downloading: String(localized: "Downloading")
        case .applying: String(localized: "Applying")
        case .installing: String(localized: "Installing")
        case .restarting: String(localized: "Restarting")
        case .finished: String(localized: "Done")
        }
    }
}
