import AVFoundation
import Foundation
import NaturalLanguage

@MainActor
final class SpeechSpeaker: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var outstanding = 0
    var onDrained: (() -> Void)?

    var isSpeaking: Bool { outstanding > 0 }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ sentence: String) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        if let language = Self.dominantLanguage(of: text), let voice = AVSpeechSynthesisVoice(language: language) {
            utterance.voice = voice
        }
        outstanding += 1
        synthesizer.speak(utterance)
    }

    func stop() {
        guard outstanding > 0 else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    private static func dominantLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    fileprivate func utteranceEnded() {
        outstanding = max(0, outstanding - 1)
        if outstanding == 0 { onDrained?() }
    }
}

extension SpeechSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }
}
