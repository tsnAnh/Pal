import PalChat

extension BubbleDelivery {
    static func awaitingReceipt(outbox: OutboxEntry?) -> BubbleDelivery {
        outbox?.state.isAdmitted == true ? .sent : .sending
    }
}
