import Foundation
import Observation

@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case starting
        case listening
    }

    private(set) var state: State = .idle
    private(set) var failure: String?

    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private var base = ""
    @ObservationIgnored private var startTask: Task<Void, Never>?

    var isActive: Bool { state != .idle }

    func toggle(currentText: String, apply: @escaping @MainActor (String) -> Void) {
        if isActive {
            stop()
            return
        }
        failure = nil
        base = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .starting
        startTask = Task { [weak self] in
            guard let self else { return }
            guard await SpeechListener.requestPermission() else {
                finish(with: .permissionDenied)
                return
            }
            guard !Task.isCancelled, state == .starting else { return }
            do {
                try beginListening(apply: apply)
            } catch let error as SpeechListenerError {
                finish(with: error)
            } catch {
                finish(with: .audioFailure)
            }
        }
    }

    private func beginListening(apply: @escaping @MainActor (String) -> Void) throws {
        try listener.start { [weak self] event in self?.handle(event, apply: apply) }
        state = .listening
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        listener.stop()
        state = .idle
    }

    func dismissFailure() {
        failure = nil
    }

    private func finish(with error: SpeechListenerError) {
        listener.stop()
        state = .idle
        failure = error.userMessage
    }

    private func handle(_ event: SpeechListenerEvent, apply: @escaping @MainActor (String) -> Void) {
        guard state == .listening else { return }
        switch event {
        case .partial(let text):
            apply(joined(text))
        case .final(let text):
            apply(joined(text))
            stop()
        case .failed:
            stop()
        }
    }

    private func joined(_ spoken: String) -> String {
        base.isEmpty ? spoken : base + " " + spoken
    }
}
