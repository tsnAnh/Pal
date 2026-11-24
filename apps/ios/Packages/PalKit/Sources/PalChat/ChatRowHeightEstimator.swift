import Foundation

public enum ChatRowShapeKind: String, Sendable, Codable, CaseIterable {
    case user
    case assistant
    case card
}

public struct ChatRowShape: Sendable, Equatable {
    public var kind: ChatRowShapeKind
    public var characters: Int
    public var lineBreaks: Int
    public var images: Int
    public var files: Int

    public init(kind: ChatRowShapeKind, characters: Int = 0, lineBreaks: Int = 0, images: Int = 0, files: Int = 0) {
        self.kind = kind
        self.characters = characters
        self.lineBreaks = lineBreaks
        self.images = images
        self.files = files
    }
}

public struct ChatRowHeightEstimator: Sendable, Equatable {
    public static let sampleLimit = 24
    public static let scaleRange: ClosedRange<Double> = 0.4...2.5

    private var samples: [ChatRowShapeKind: [Double]] = [:]

    public init() {}

    public func estimate(_ shape: ChatRowShape, width: Double, lineHeight: Double) -> Double {
        max(24, Self.base(shape, width: width, lineHeight: lineHeight) * scale(for: shape.kind))
    }

    public mutating func observe(_ shape: ChatRowShape, measured: Double, width: Double, lineHeight: Double) {
        guard measured > 0, width > 0, lineHeight > 0, measured.isFinite, width.isFinite, lineHeight.isFinite else { return }
        let base = Self.base(shape, width: width, lineHeight: lineHeight)
        guard base > 0 else { return }
        let ratio = min(max(measured / base, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        var kept = samples[shape.kind] ?? []
        kept.append(ratio)
        if kept.count > Self.sampleLimit { kept.removeFirst(kept.count - Self.sampleLimit) }
        samples[shape.kind] = kept
    }

    public func scale(for kind: ChatRowShapeKind) -> Double {
        guard let kept = samples[kind], !kept.isEmpty else { return 1 }
        let sorted = kept.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    private static func base(_ shape: ChatRowShape, width: Double, lineHeight: Double) -> Double {
        let columns = max(8.0, ((width - 32) / (lineHeight * 0.45)).rounded(.down))
        let characters = Double(max(0, shape.characters))
        let breaks = Double(max(0, shape.lineBreaks))
        let attachments = Double(max(0, shape.images)) * min(width * 0.6, 320) + Double(max(0, shape.files)) * 56
        switch shape.kind {
        case .user:
            let lines = max(1, (characters / (columns * 0.8)).rounded(.up)) + breaks
            return lines * lineHeight + 26
        case .assistant:
            let lines = max(1, (characters / columns).rounded(.up)) + breaks
            return lines * lineHeight + breaks * lineHeight * 0.4 + attachments + 18
        case .card:
            return 72 + attachments
        }
    }
}
