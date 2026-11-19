import PalProtocol

extension Timeline {
    mutating func addServerClarify(_ prompt: PendingPrompt) {
        live.addCard(prompt)
        assignLiveKeys()
    }
}
