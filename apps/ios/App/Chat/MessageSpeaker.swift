import Observation
import PalChat

@MainActor
@Observable
final class MessageSpeaker {
    static let shared = MessageSpeaker()

    private(set) var speakingRowID: String?
    @ObservationIgnored private let speaker = SpeechSpeaker()

    private init() {
        speaker.onDrained = { [weak self] in self?.speakingRowID = nil }
    }

    func toggle(rowID: String, text: String) {
        if speakingRowID == rowID {
            stop()
            return
        }
        stop()
        var chunker = SpeechChunker()
        let chunks = chunker.consume(text, isFinal: true)
        guard !chunks.isEmpty else { return }
        speakingRowID = rowID
        chunks.forEach(speaker.speak)
    }

    func stop() {
        speaker.stop()
        speakingRowID = nil
    }
}
