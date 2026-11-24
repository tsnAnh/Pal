import Foundation
import PalChat
import Testing

private func record(_ id: String, _ height: Double = 100) -> ChatRowHeightRecord {
    ChatRowHeightRecord(id: id, hash: 1, height: height)
}

@Suite("Chat row height file")
struct ChatRowHeightFileTests {
    @Test func roundTripsThroughJSON() throws {
        let file = ChatRowHeightFile(width: 900, textScale: "large", rows: [record("a", 40), record("b", 80)])
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(ChatRowHeightFile.self, from: data)
        #expect(decoded == file)
    }

    @Test func recordsComeBackOnlyForTheSameLayout() {
        let file = ChatRowHeightFile(width: 900, textScale: "large", rows: [record("a")])
        #expect(file.records(width: 900, textScale: "large").count == 1)
        #expect(file.records(width: 900.5, textScale: "large").count == 1)
        #expect(file.records(width: 901, textScale: "large").isEmpty)
        #expect(file.records(width: 900, textScale: "small").isEmpty)
        var stale = file
        stale.layout = ChatRowHeightFile.layoutVersion + 1
        #expect(stale.records(width: 900, textScale: "large").isEmpty)
    }

    @Test func capacityKeepsTheNewestRows() {
        let rows = (0..<(ChatRowHeightFile.capacity + 50)).map { record("r\($0)") }
        let file = ChatRowHeightFile(width: 900, textScale: "large", rows: rows)
        #expect(file.rows.count == ChatRowHeightFile.capacity)
        #expect(file.rows.first?.id == "r50")
        #expect(file.rows.last?.id == "r\(ChatRowHeightFile.capacity + 49)")
    }

    @Test func duplicatesAndNonPositiveHeightsAreDropped() {
        let file = ChatRowHeightFile(
            width: 900, textScale: "large",
            rows: [record("a", 10), record("b", 0), record("c", -4), record("d", .infinity), record("a", 20), record("e", 30)]
        )
        #expect(file.rows.map(\.id) == ["a", "e"])
        #expect(file.records(width: 900, textScale: "large")["a"]?.height == 20)
    }

    @Test func cacheNameCarriesTheBot() {
        #expect(ChatRowHeightFile.cacheName(forBot: "pi") == "row-heights-pi")
    }
}

@Suite("Chat row fingerprint")
struct ChatRowFingerprintTests {
    @Test func theEmptyListHashesToTheFNVOffsetBasis() {
        #expect(ChatRowFingerprint.hash([]) == 0xcbf29ce484222325)
    }

    @Test func aSinglePartFollowsFNV1aWithATerminator() {
        var value: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte: UInt8 in [0x61, 0xFF] {
            value ^= UInt64(byte)
            value = value &* prime
        }
        #expect(ChatRowFingerprint.hash(["a"]) == value)
    }

    @Test func partBoundariesAndOrderMatter() {
        #expect(ChatRowFingerprint.hash(["ab", "c"]) != ChatRowFingerprint.hash(["a", "bc"]))
        #expect(ChatRowFingerprint.hash(["a", "b"]) != ChatRowFingerprint.hash(["b", "a"]))
        #expect(ChatRowFingerprint.hash(["a", "b"]) == ChatRowFingerprint.hash(["a", "b"]))
    }
}
