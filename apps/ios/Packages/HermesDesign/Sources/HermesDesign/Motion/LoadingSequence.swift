import Foundation

struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct LoadingSequence: Sendable {
    let seed: UInt64

    static func seed(for key: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return hash
    }

    init(seed: UInt64) {
        self.seed = seed
    }

    init(key: String) {
        self.init(seed: Self.seed(for: key))
    }

    func bag(_ index: Int) -> [Int] {
        var order = shuffled(index)
        if index >= 1, order[0] == shuffled(index - 1)[order.count - 1] {
            order.swapAt(0, 1)
        }
        return order
    }

    func clipIndices(first count: Int) -> [Int] {
        var indices: [Int] = []
        var index = 0
        while indices.count < count {
            indices += bag(index)
            index += 1
        }
        return Array(indices.prefix(count))
    }

    func pose(at t: Double) -> AvatarPose {
        let clips = LoadingClips.all
        let cycle = LoadingClips.cycleDuration
        let time = max(t, 0)
        let index = (time / cycle).rounded(.down)
        var remaining = time - index * cycle
        let order = bag(Int(index))
        for clipIndex in order {
            let clip = clips[clipIndex]
            if remaining < clip.duration { return clip.track.pose(at: remaining) }
            remaining -= clip.duration
        }
        let last = clips[order[order.count - 1]]
        return last.track.pose(at: last.duration)
    }

    private func shuffled(_ index: Int) -> [Int] {
        var generator = SplitMix64(seed: seed ^ (UInt64(index) &* 0x9E37_79B9_7F4A_7C15))
        var order = Array(0..<LoadingClips.all.count)
        for i in stride(from: order.count - 1, through: 1, by: -1) {
            order.swapAt(i, Int(generator.next() % UInt64(i + 1)))
        }
        return order
    }
}
