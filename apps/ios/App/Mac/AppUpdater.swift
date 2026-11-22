#if os(macOS)
import Foundation
import Observation
import Sparkle

@MainActor
protocol UpdateNotices: AnyObject {
    var restartForUpdate: (@MainActor () -> Void)? { get set }
    func announceUpdate(version: String) async
    func withdrawUpdate()
}

@MainActor
struct StagedUpdate {
    let version: String
    let install: () -> Void
}

@MainActor
@Observable
final class AppUpdater {
    private(set) var staged: StagedUpdate?
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let delegate: StagingDelegate
    @ObservationIgnored private let notices: any UpdateNotices

    static func make(notices: any UpdateNotices, bundle: Bundle = .main) -> AppUpdater? {
        guard UpdateFeed.isConfigured(in: bundle) else { return nil }
        return AppUpdater(notices: notices)
    }

    private init(notices: any UpdateNotices) {
        let delegate = StagingDelegate()
        self.delegate = delegate
        self.notices = notices
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        delegate.onStaged = { [weak self] update in self?.stage(update) }
        notices.restartForUpdate = { [weak self] in self?.restartToUpdate() }
    }

    func start() {
        notices.withdrawUpdate()
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = true
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func restartToUpdate() {
        guard let staged else { return }
        notices.withdrawUpdate()
        staged.install()
    }

    private func stage(_ update: StagedUpdate) {
        staged = update
        Task { await notices.announceUpdate(version: update.version) }
    }
}

enum UpdateFeed {
    static func isConfigured(in bundle: Bundle) -> Bool {
        ["SUFeedURL", "SUPublicEDKey"].allSatisfy { key in
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return false }
            return !value.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

private final class StagingDelegate: NSObject, SPUUpdaterDelegate {
    var onStaged: ((StagedUpdate) -> Void)?

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        guard let onStaged else { return false }
        onStaged(StagedUpdate(version: Self.label(for: item), install: immediateInstallHandler))
        return true
    }

    private static func label(for item: SUAppcastItem) -> String {
        let display = item.displayVersionString
        return display == item.versionString ? display : "\(display) (\(item.versionString))"
    }
}
#endif
