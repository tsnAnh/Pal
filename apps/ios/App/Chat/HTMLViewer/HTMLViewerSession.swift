import Foundation
import Observation
import PalChat
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
@Observable
final class HTMLViewerCoordinator {
    static let shared = HTMLViewerCoordinator()

    private(set) var session: HTMLViewerSession?

    func open(_ file: FileReference, source: any MediaAssetSource, owner: ObjectIdentifier) {
        close()
        let next = HTMLViewerSession(file: file, source: source, owner: owner)
        session = next
        next.start()
    }

    func close() {
        session?.stop()
        session = nil
    }
}

@MainActor
@Observable
final class HTMLViewerSession {
    enum Fetch: Equatable {
        case fetching(Double?)
        case tooLarge(Int?)
        case failed(message: String, retryable: Bool)
        case ready(URL)
    }

    let file: FileReference
    let owner: ObjectIdentifier
    private(set) var fetch = Fetch.fetching(nil)
    private(set) var render = HTMLRenderState()
    private(set) var transfer = MediaFilePhase.idle
    private(set) var confirmation: HTMLExternalOpen?
    private(set) var notice: HTMLBlockedAction?

    @ObservationIgnored private let source: any MediaAssetSource
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var transferTask: Task<Void, Never>?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var memoryGuard: MemoryGuard?

    init(file: FileReference, source: any MediaAssetSource, owner: ObjectIdentifier) {
        self.file = file
        self.source = source
        self.owner = owner
    }

    private var media: MediaReference { MediaReference(file: file) }

    var pageURL: URL? {
        if case .ready(let url) = fetch { url } else { nil }
    }

    func start() {
        memoryGuard = MemoryGuard { [weak self] in self?.releaseUnderMemoryPressure() }
        fetchPage()
    }

    func stop() {
        fetchTask?.cancel()
        transferTask?.cancel()
        timeout?.cancel()
        memoryGuard?.stop()
        memoryGuard = nil
        if let pageURL { MediaDownloads.remove(pageURL) }
        fetch = .fetching(nil)
    }

    func retryFetch() {
        fetchPage()
    }

    func retryRender() {
        guard render.retry() else { return }
        restartTimeout()
    }

    func toggleOnline() {
        guard render.toggleOnline() else { return }
        confirmation = nil
        restartTimeout()
    }

    func webFinished() {
        render.finish()
        timeout?.cancel()
    }

    func webFailed(_ failure: HTMLRenderState.Failure) {
        render.fail(failure)
        timeout?.cancel()
    }

    func apply(_ decision: HTMLPolicyDecision) {
        switch decision {
        case .allow, .cancel: break
        case .confirmOpen(let request): confirmation = request
        case .blocked(let action): notice = action
        }
    }

    func askToOpenPageInBrowser() {
        guard let pageURL else { return }
        confirmation = HTMLExternalOpen(url: pageURL, reason: .page)
    }

    func confirmOpen() {
        guard let request = confirmation else { return }
        confirmation = nil
        HTMLExternalOpener.open(request)
    }

    func dismissConfirmation() {
        confirmation = nil
    }

    func dismissNotice() {
        notice = nil
    }

    func save() {
        guard let pageURL else { return }
        #if os(macOS)
        MediaFileActions.saveAs(pageURL, suggestedName: file.name)
        #else
        SharePresenter.present(items: [pageURL])
        #endif
    }

    func downloadWhole() {
        guard transferTask == nil else { return }
        let name = file.name
        transferTask = MediaFetch.run(
            media, source: source, limit: MediaLimits.downloadBytes,
            progress: { [weak self] in self?.transfer = .fetching($0) },
            completion: { [weak self] phase in
                self?.transferTask = nil
                guard case .ready(let url) = phase else {
                    self?.transfer = phase
                    return
                }
                self?.transfer = .idle
                MediaFileActions.deliver(url, name: name)
            }
        )
    }

    private func fetchPage() {
        fetchTask?.cancel()
        fetch = .fetching(nil)
        let media = media
        let source = source
        fetchTask = Task { [weak self] in
            do {
                let url = try await MediaDownloads.download(media, from: source, limit: HTMLPreviewLimits.liveRenderBytes) { update in
                    Task { @MainActor in self?.fetchProgressed(update.fraction) }
                }
                guard let self, !Task.isCancelled else {
                    MediaDownloads.remove(url)
                    return
                }
                fetch = .ready(url)
                _ = render.begin()
                restartTimeout()
            } catch is CancellationError {
            } catch MediaTransferError.tooLarge(let size) {
                self?.fetch = .tooLarge(size)
            } catch {
                let failure = MediaFailure(describing: error)
                self?.fetch = .failed(message: failure.message, retryable: failure.retryable)
            }
        }
    }

    private func fetchProgressed(_ fraction: Double?) {
        if case .fetching = fetch { fetch = .fetching(fraction) }
    }

    private func restartTimeout() {
        timeout?.cancel()
        guard render.phase == .loading else { return }
        let generation = render.generation
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(HTMLPreviewLimits.loadTimeout))
            guard !Task.isCancelled, let self, render.generation == generation else { return }
            webFailed(.timedOut)
        }
    }

    private func releaseUnderMemoryPressure() {
        guard HTMLViewerCoordinator.shared.session === self else { return }
        HTMLViewerCoordinator.shared.close()
    }
}

@MainActor
enum HTMLExternalOpener {
    static func open(_ request: HTMLExternalOpen) {
        let url = request.url
        #if os(macOS)
        if request.reason == .page {
            openInBrowser(url)
            return
        }
        #endif
        if ExternalLink.open(url) { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    #if os(macOS)
    private static func openInBrowser(_ file: URL) {
        guard let probe = URL(string: "https://localhost"), let browser = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return }
        NSWorkspace.shared.open([file], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
    }
    #endif
}

@MainActor
private final class MemoryGuard {
    #if os(iOS)
    private var token: (any NSObjectProtocol)?
    #else
    private var source: DispatchSourceMemoryPressure?
    #endif

    init(onPressure: @escaping @MainActor () -> Void) {
        #if os(iOS)
        token = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in onPressure() }
        }
        #else
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { Task { @MainActor in onPressure() } }
        pressure.resume()
        source = pressure
        #endif
    }

    func stop() {
        #if os(iOS)
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        #else
        source?.cancel()
        source = nil
        #endif
    }
}
