import PalProtocol

extension TranscriptItem.Content {
    static func reply(_ text: String, reasoning: String, from row: some InboundRowWire) -> Self {
        row.isFailedTurnNeedingModelProvider ? .noProvider : .assistant(text: text, reasoning: reasoning, isStreaming: false)
    }
}
