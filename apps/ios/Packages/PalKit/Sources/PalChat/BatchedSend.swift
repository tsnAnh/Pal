import PalProtocol

enum BatchedSend {
    typealias Row = (TranscriptItem, [TimelineRef])

    static func rows(_ row: Row, from wire: TimelineEntryWire) -> [Row] {
        let admissions = wire.displayMetadata?["admission_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let lengths = wire.displayMetadata?["part_lengths"]?.arrayValue?.compactMap(\.intValue) ?? []
        guard lengths.count == admissions.count, let texts = split(wire.text, lengths: lengths) else {
            return [covering(row, admissions)]
        }
        return zip(texts, admissions).enumerated().map { index, send in
            var (item, refs) = row
            if index > 0 {
                item.id = "\(wire.id)#\(index)"
                item.submissionID = nil
                refs = [.entry(item.id)]
            }
            item.content = .user(text: send.0, delivery: .sent)
            return covering((item, refs), [send.1])
        }
    }

    private static func covering(_ row: Row, _ admissions: [String]) -> Row {
        var (item, refs) = row
        item.admissionIDs = admissions
        return (item, refs + admissions.map(TimelineRef.admission))
    }

    private static func split(_ text: String, lengths: [Int]) -> [String]? {
        let scalars = text.unicodeScalars
        guard lengths.count > 1, lengths.allSatisfy({ $0 > 0 && $0 <= scalars.count }),
              lengths.reduce(lengths.count - 1, +) == scalars.count
        else { return nil }
        var rest = scalars[...]
        var parts: [String] = []
        for length in lengths {
            parts.append(String(Substring(rest.prefix(length))))
            rest = rest.dropFirst(length)
            guard rest.isEmpty || rest.first == "\n" else { return nil }
            rest = rest.dropFirst()
        }
        return parts
    }
}

extension Transcript {
    func admissionID(ofEcho itemID: String) -> String? {
        guard let input = Self.submissionID(ofEcho: itemID) else { return nil }
        return admissionInputs.first { $0.value == input }?.key ?? input
    }
}
