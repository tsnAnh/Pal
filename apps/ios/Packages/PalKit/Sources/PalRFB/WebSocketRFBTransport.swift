import Foundation
import PalDiagnostics
import Synchronization

public final class WebSocketRFBTransport: RFBTransport, @unchecked Sendable {
    private static let maximumMessageBytes = 8 * 1024 * 1024

    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let closeCode = Mutex<Int?>(nil)

    public init(url: URL, diagnostics: Diagnostics = .silent) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let delegate = CloseObserver()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = Self.maximumMessageBytes
        delegate.owner = self
        diagnostics.info("rfb", "dialing \(Diagnostics.describe(url))")
        task.resume()
    }

    public func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    public func receive() async throws -> Data {
        do {
            switch try await task.receive() {
            case .data(let data): return data
            case .string: throw RFBTransportError.textFrame
            @unknown default: throw RFBTransportError.textFrame
            }
        } catch let error as RFBTransportError {
            throw error
        } catch {
            throw RFBTransportError.closed(code: await observedCloseCode())
        }
    }

    public func close() async {
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }

    fileprivate func record(closeCode code: Int) {
        closeCode.withLock { $0 = code }
    }

    private func observedCloseCode() async -> Int? {
        for _ in 0..<20 {
            let recorded = closeCode.withLock { $0 }
            if recorded != nil { return recorded }
            let reported = task.closeCode
            if reported != .invalid { return reported.rawValue }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

private final class CloseObserver: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    weak var owner: WebSocketRFBTransport?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        owner?.record(closeCode: closeCode.rawValue)
    }
}
