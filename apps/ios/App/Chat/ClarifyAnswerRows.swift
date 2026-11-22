import PalChat

extension ChatRow {
    static func mergingClarifyAnswers(_ rows: [ChatRow], sources: @autoclosure () -> [(id: String, itemID: String)]) -> [ChatRow] {
        guard rows.contains(where: { if case .clarifyAnswered = $0.kind { true } else { false } }) else { return rows }
        let calls = Dictionary(sources().map { ($0.id, ClarifyRecord.callID(ofItemID: $0.itemID)) }, uniquingKeysWith: { first, _ in first })
        var merged: [ChatRow] = []
        var openCall: String?
        for row in rows {
            guard case .clarifyAnswered(let records) = row.kind, let call = calls[row.id] ?? nil else {
                merged.append(row)
                openCall = nil
                continue
            }
            guard call == openCall, let previous = merged.last, case .clarifyAnswered(let earlier) = previous.kind else {
                merged.append(row)
                openCall = call
                continue
            }
            merged[merged.count - 1] = previous.replacingKind(.clarifyAnswered(earlier + records))
        }
        return merged
    }

    private func replacingKind(_ kind: Kind) -> ChatRow {
        var row = ChatRow(id: id, kind: kind, separator: separator, showsUnreadDivider: showsUnreadDivider)
        row.storedRowID = storedRowID
        return row
    }
}
