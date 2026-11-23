@testable import PalChat
import Foundation
import Testing

@Suite("Media preview loader state")
struct MediaPreviewLoaderTests {
    private let preview = MediaPreview(poster: Data([1]), duration: 3, size: 10, width: 4, height: 3)

    private func loading() -> MediaPreviewLoader {
        var loader = MediaPreviewLoader()
        _ = loader.start()
        return loader
    }

    private func failed(retryable: Bool) -> MediaPreviewLoader {
        var loader = loading()
        loader.finish(.failed(reason: "nope", retryable: retryable))
        return loader
    }

    @Test("start moves idle to loading once")
    func startOnce() {
        var loader = MediaPreviewLoader()
        #expect(loader.state == .idle)
        #expect(!loader.isLoading)
        let first = loader.start()
        #expect(first)
        #expect(loader.state == .loading)
        #expect(loader.isLoading)
        let second = loader.start()
        #expect(!second)
        #expect(loader.state == .loading)
    }

    @Test("finishing a load stores the outcome")
    func finishStores() {
        var ready = loading()
        ready.finish(.ready(preview))
        #expect(ready.state == .ready(preview))
        #expect(!ready.isLoading)

        var large = loading()
        large.finish(.tooLarge(size: 300_000_000))
        #expect(large.state == .tooLarge(size: 300_000_000))

        #expect(failed(retryable: true).state == .failed(reason: "nope", retryable: true))
    }

    @Test("a finish that arrives when nothing is loading is ignored")
    func finishIgnoredUnlessLoading() {
        var idle = MediaPreviewLoader()
        idle.finish(.ready(preview))
        #expect(idle.state == .idle)

        var ready = MediaPreviewLoader(state: .ready(preview))
        ready.finish(.failed(reason: "late", retryable: true))
        #expect(ready.state == .ready(preview))

        var done = failed(retryable: false)
        done.finish(.ready(preview))
        #expect(done.state == .failed(reason: "nope", retryable: false))
    }

    @Test("finishing with idle or loading changes nothing")
    func finishWithNonOutcomes() {
        var loader = loading()
        loader.finish(.idle)
        #expect(loader.state == .loading)
        loader.finish(.loading)
        #expect(loader.state == .loading)
    }

    @Test("cancel returns a running load to idle and leaves settled states alone")
    func cancel() {
        var running = loading()
        running.cancel()
        #expect(running.state == .idle)
        let restarted = running.start()
        #expect(restarted)

        var ready = MediaPreviewLoader(state: .ready(preview))
        ready.cancel()
        #expect(ready.state == .ready(preview))

        var broken = failed(retryable: true)
        broken.cancel()
        #expect(broken.state == .failed(reason: "nope", retryable: true))
    }

    @Test("a transient failure can retry and a permanent one cannot")
    func retry() {
        var transient = failed(retryable: true)
        let retried = transient.retry()
        #expect(retried)
        #expect(transient.state == .loading)

        var permanent = failed(retryable: false)
        let refused = permanent.retry()
        #expect(!refused)
        #expect(permanent.state == .failed(reason: "nope", retryable: false))
    }

    @Test("too large and other states never retry")
    func retryRefused() {
        var large = MediaPreviewLoader(state: .tooLarge(size: nil))
        let largeRetry = large.retry()
        #expect(!largeRetry)
        #expect(large.state == .tooLarge(size: nil))

        var idle = MediaPreviewLoader()
        let idleRetry = idle.retry()
        #expect(!idleRetry)
        #expect(idle.state == .idle)

        var ready = MediaPreviewLoader(state: .ready(preview))
        let readyRetry = ready.retry()
        #expect(!readyRetry)
    }

    @Test("start does not leave a failed state")
    func startFromFailed() {
        var loader = failed(retryable: true)
        let started = loader.start()
        #expect(!started)
        #expect(loader.state == .failed(reason: "nope", retryable: true))
    }
}
