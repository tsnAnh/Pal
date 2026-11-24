import Foundation
import Synchronization

public enum ChatSendTrace {
    private static let enabled = PalPerf.isRequested()
    private static let state = Mutex(State())

    private struct State {
        var starts: [String: ContinuousClock.Instant] = [:]
        var awaitingToken: Set<String> = []
    }

    public static func begin(submission: String) {
        guard enabled else { return }
        state.withLock { $0.starts[submission] = .now }
        mark(submission, "tap")
    }

    public static func mark(_ submission: String, _ step: String) {
        guard enabled, let start = state.withLock({ $0.starts[submission] }) else { return }
        PalPerf.event("chat.send.step", label: "\(String(submission.prefix(8))) \(step)", since: start)
    }

    public static func receipt(_ submission: String, status: String) {
        guard enabled else { return }
        state.withLock { _ = $0.awaitingToken.insert(submission) }
        mark(submission, "receipt \(status)")
    }

    public static var isEnabled: Bool { enabled }

    public static func firstToken() {
        guard enabled else { return }
        let ready = state.withLock { state -> [String] in
            let ready = Array(state.awaitingToken)
            state.awaitingToken.removeAll()
            return ready
        }
        for submission in ready {
            mark(submission, "first.token")
            state.withLock { $0.starts[submission] = nil }
        }
    }
}
