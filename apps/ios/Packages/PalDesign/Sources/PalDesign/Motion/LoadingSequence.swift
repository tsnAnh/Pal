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
    let interleavesSolid: Bool

    static let solidSalt: UInt64 = 0xD1B5_4A32_D192_ED03

    static func seed(for key: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return hash
    }

    init(seed: UInt64, interleavesSolid: Bool = true) {
        self.seed = seed
        self.interleavesSolid = interleavesSolid
    }

    init(key: String, interleavesSolid: Bool = true) {
        self.init(seed: Self.seed(for: key), interleavesSolid: interleavesSolid)
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

    func solidBag(_ index: Int) -> [Int] {
        var order = shuffled(index, count: SolidClips.all.count, salt: Self.solidSalt)
        if index >= 1, order[0] == shuffled(index - 1, count: order.count, salt: Self.solidSalt)[order.count - 1] {
            order.swapAt(0, 1)
        }
        return order
    }

    func pose(at t: Double) -> AvatarPose {
        interleavesSolid ? interleavedPose(at: t) : flatPose(at: t)
    }

    func clips(inSuperCycle index: Int) -> [LoadingClip] {
        let flat = LoadingClips.all
        let solid = SolidClips.all
        let flatOrder = (0..<Self.superCycleBags.flat).flatMap { bag(index * Self.superCycleBags.flat + $0) }
        let solidOrder = (0..<Self.superCycleBags.solid).flatMap { solidBag(index * Self.superCycleBags.solid + $0) }
        return zip(flatOrder, solidOrder).flatMap { [flat[$0], solid[$1]] }
    }

    static let superCycleBags: (flat: Int, solid: Int) = {
        let flat = LoadingClips.all.count
        let solid = SolidClips.all.count
        let shared = lcm(flat, solid)
        return (shared / flat, shared / solid)
    }()

    static let superCycleDuration: Double =
        Double(superCycleBags.flat) * LoadingClips.cycleDuration + Double(superCycleBags.solid) * SolidClips.cycleDuration

    private static func lcm(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (a, b)
        while y != 0 { (x, y) = (y, x % y) }
        return a / x * b
    }

    private func flatPose(at t: Double) -> AvatarPose {
        let clips = LoadingClips.all
        let cycle = LoadingClips.cycleDuration
        let time = max(t, 0)
        let index = (time / cycle).rounded(.down)
        return Self.walk(clips: bag(Int(index)).map { clips[$0] }, at: time - index * cycle)
    }

    private func interleavedPose(at t: Double) -> AvatarPose {
        let time = max(t, 0)
        let index = (time / Self.superCycleDuration).rounded(.down)
        return Self.walk(clips: clips(inSuperCycle: Int(index)), at: time - index * Self.superCycleDuration)
    }

    private static func walk(clips: [LoadingClip], at time: Double) -> AvatarPose {
        var remaining = time
        for clip in clips {
            if remaining < clip.duration { return clip.pose(at: remaining) }
            remaining -= clip.duration
        }
        guard let last = clips.last else { return .facing }
        return last.pose(at: last.duration)
    }

    private func shuffled(_ index: Int) -> [Int] {
        shuffled(index, count: LoadingClips.all.count, salt: 0)
    }

    private func shuffled(_ index: Int, count: Int, salt: UInt64) -> [Int] {
        var generator = SplitMix64(seed: seed ^ salt ^ (UInt64(index) &* 0x9E37_79B9_7F4A_7C15))
        var order = Array(0..<count)
        for i in stride(from: order.count - 1, through: 1, by: -1) {
            order.swapAt(i, Int(generator.next() % UInt64(i + 1)))
        }
        return order
    }
}
