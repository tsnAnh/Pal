import Foundation
import PalChat
import Observation

@MainActor
@Observable
final class VoiceConversation {
    enum Phase: Equatable {
        case starting
        case listening
        case thinking
        case speaking
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    private(set) var transcript = ""

    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private let speaker = SpeechSpeaker()
    @ObservationIgnored private var chunker = SpeechChunker()
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var baselineTurn = 0
    @ObservationIgnored private var sawReplyRunning = false
    @ObservationIgnored private var replyComplete = false
    @ObservationIgnored private var abandonedReply = false
    @ObservationIgnored private var isEnded = false
    @ObservationIgnored private let currentTurn: @MainActor () -> Int
    @ObservationIgnored private let submit: @MainActor (String) async -> Bool

    static let silenceWindow: Duration = .milliseconds(1400)
    static let replyTimeout: Duration = .seconds(120)

    init(currentTurn: @escaping @MainActor () -> Int, submit: @escaping @MainActor (String) async -> Bool) {
        self.currentTurn = currentTurn
        self.submit = submit
        speaker.onDrained = { [weak self] in self?.speakerDrained() }
    }

    func begin() async {
        phase = .starting
        guard await SpeechListener.requestPermission() else {
            phase = .failed(SpeechListenerError.permissionDenied.userMessage)
            return
        }
        guard !isEnded else { return }
        listen()
    }

    func retry() {
        Task { await begin() }
    }

    func end() {
        isEnded = true
        silenceTask?.cancel()
        watchdogTask?.cancel()
        listener.stop()
        speaker.onDrained = nil
        speaker.stop()
    }

    func interrupt() {
        guard phase == .speaking || phase == .thinking else { return }
        abandonedReply = true
        speaker.onDrained = nil
        speaker.stop()
        speaker.onDrained = { [weak self] in self?.speakerDrained() }
        watchdogTask?.cancel()
        listen()
    }

    func ingest(_ reply: VoiceReply) {
        guard !isEnded, !abandonedReply, phase == .thinking || phase == .speaking, reply.turn > baselineTurn else { return }
        if !reply.isComplete { sawReplyRunning = true }
        let chunks = chunker.consume(reply.text, isFinal: reply.isComplete && sawReplyRunning)
        for chunk in chunks {
            phase = .speaking
            speaker.speak(chunk)
        }
        if reply.isComplete, sawReplyRunning {
            replyComplete = true
            watchdogTask?.cancel()
            if !speaker.isSpeaking { listen() }
        }
    }

    private func listen() {
        guard !isEnded else { return }
        transcript = ""
        chunker.reset()
        replyComplete = false
        sawReplyRunning = false
        abandonedReply = false
        do {
            try listener.start { [weak self] event in self?.handle(event) }
            phase = .listening
        } catch let error as SpeechListenerError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed(SpeechListenerError.audioFailure.userMessage)
        }
    }

    private func handle(_ event: SpeechListenerEvent) {
        guard phase == .listening else { return }
        switch event {
        case .partial(let text):
            transcript = text
            armSilenceTimer()
        case .final(let text):
            transcript = text
            commit()
        case .failed:
            phase = .failed(SpeechListenerError.recognizerUnavailable.userMessage)
            listener.stop()
        }
    }

    private func armSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task {
            try? await Task.sleep(for: Self.silenceWindow)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func commit() {
        silenceTask?.cancel()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .listening, !text.isEmpty else { return }
        listener.stop()
        baselineTurn = currentTurn()
        phase = .thinking
        watchdogTask?.cancel()
        watchdogTask = Task {
            try? await Task.sleep(for: Self.replyTimeout)
            guard !Task.isCancelled, phase == .thinking else { return }
            listen()
        }
        Task {
            guard await submit(text) else {
                phase = .failed(String(localized: "Your message could not be sent. Try again."))
                return
            }
        }
    }

    private func speakerDrained() {
        guard !isEnded else { return }
        if replyComplete {
            listen()
        } else if phase == .speaking {
            phase = .thinking
        }
    }
}
