import Foundation

struct BlobTraits {
    private let state: UInt32
    private let overrides: [String: Double]

    init(seed: String, overrides: [String: Double] = [:]) {
        self.state = Self.seedState(JSCompat.normalizeSeed(seed))
        self.overrides = overrides
    }

    private static let separator: UInt8 = 0xFF

    private static func feed(_ start: UInt32, _ bytes: some Sequence<UInt8>) -> UInt32 {
        var h = start
        for byte in bytes {
            h = (h ^ UInt32(byte)) &* 3_432_918_353
            h = (h << 13) | (h >> 19)
        }
        return h
    }

    private static func finalize(_ value: UInt32) -> UInt32 {
        var h = value
        h = (h ^ (h >> 16)) &* 2_246_822_507
        h = (h ^ (h >> 13)) &* 3_266_489_909
        return h ^ (h >> 16)
    }

    private static func seedState(_ normalized: String) -> UInt32 {
        let start = UInt32(truncatingIfNeeded: 1_779_033_703 ^ normalized.utf16.count)
        return feed(start, normalized.utf8)
    }

    private func stream(_ key: String) -> Double {
        let mixed = Self.feed(Self.feed(state, [Self.separator]), key.utf8)
        return Double(Self.finalize(mixed)) / 4_294_967_296
    }

    func callAsFunction(_ key: String) -> Double {
        guard let override = overrides[key] else { return stream(key) }
        if override > 0 { return override < 1 ? override : 0.999999 }
        return 0
    }

    func num(_ key: String, _ min: Double, _ max: Double) -> Double {
        min + self(key) * (max - min)
    }

    func int(_ key: String, _ min: Int, _ max: Int) -> Int {
        min + Int((self(key) * Double(max - min + 1)).rounded(.down))
    }

    func jitter(_ key: String, _ amount: Double) -> Double {
        (self(key) * 2 - 1) * amount
    }
}
