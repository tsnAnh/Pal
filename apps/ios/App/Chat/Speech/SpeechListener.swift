import AVFoundation
import Foundation
import Speech

enum SpeechListenerError: Error, Equatable {
    case permissionDenied
    case recognizerUnavailable
    case onDeviceUnsupported
    case noMicrophone
    case audioFailure
    case nothingRecognised
}

enum SpeechListenerEvent: Sendable {
    case partial(String)
    case final(String)
    case failed
}

private final class RecognitionRequestBox: @unchecked Sendable {
    let request = SFSpeechAudioBufferRecognitionRequest()
}

@MainActor
final class SpeechListener {
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var box: RecognitionRequestBox?
    private(set) var isListening = false

    nonisolated static func requestPermission() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start(locale: Locale = .current, onEvent: @escaping @MainActor @Sendable (SpeechListenerEvent) -> Void) throws {
        stop()
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechListenerError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else { throw SpeechListenerError.onDeviceUnsupported }
        let box = RecognitionRequestBox()
        box.request.requiresOnDeviceRecognition = true
        box.request.shouldReportPartialResults = true
        box.request.taskHint = .dictation
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw SpeechListenerError.audioFailure
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechListenerError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(box))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw SpeechListenerError.audioFailure
        }
        self.box = box
        isListening = true
        task = recognizer.recognitionTask(with: box.request, resultHandler: Self.resultHandler(onEvent))
    }

    func stop() {
        guard isListening || task != nil else { return }
        isListening = false
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        box?.request.endAudio()
        task?.cancel()
        task = nil
        box = nil
    }

    nonisolated private static func tapBlock(_ box: RecognitionRequestBox) -> AVAudioNodeTapBlock {
        { buffer, _ in box.request.append(buffer) }
    }

    nonisolated private static func resultHandler(
        _ onEvent: @escaping @MainActor @Sendable (SpeechListenerEvent) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil && result == nil
            Task { @MainActor in
                if let text { onEvent(isFinal ? .final(text) : .partial(text)) } else if failed { onEvent(.failed) }
            }
        }
    }
}

extension SpeechListenerError {
    var userMessage: String {
        switch self {
        case .permissionDenied: String(localized: "Allow microphone and speech recognition for Hermes Bots in Settings to use voice.")
        case .recognizerUnavailable: String(localized: "Speech recognition isn't available right now.")
        case .onDeviceUnsupported: String(localized: "On-device speech recognition isn't available for your language on this device.")
        case .noMicrophone: String(localized: "No microphone is available on this device.")
        case .audioFailure: String(localized: "The microphone couldn't be started. Try again.")
        case .nothingRecognised: String(localized: "Couldn't catch that. Try again.")
        }
    }
}
