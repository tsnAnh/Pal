import PalChat

extension BubbleDelivery {
    /// A message is `Sending` only from tap to the gateway's receipt. The receipt marks the outbox entry
    /// admitted, and the stream echo of a queued or steered message can come seconds later, so the entry
    /// (not the echo) decides when the bubble reads as sent.
    static func awaitingReceipt(offline: Bool, outbox: OutboxEntry?) -> BubbleDelivery {
        if outbox?.state.isAdmitted == true { return .sent }
        return offline ? .waitingForConnection : .sending
    }
}
