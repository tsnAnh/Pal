import CoreGraphics
import Foundation

public struct RFBViewport: Equatable, Sendable {
    public static let minimumZoom: CGFloat = 1
    public static let maximumZoom: CGFloat = 6

    public private(set) var container: CGSize
    public private(set) var remote: RFBSize
    public private(set) var zoom: CGFloat = 1
    public private(set) var offset: CGPoint = .zero

    public init(container: CGSize, remote: RFBSize) {
        self.container = container
        self.remote = remote
    }

    public var isZoomed: Bool { zoom > Self.minimumZoom + 0.001 }

    private var fitScale: CGFloat {
        guard remote.width > 0, remote.height > 0 else { return 1 }
        return min(container.width / CGFloat(remote.width), container.height / CGFloat(remote.height))
    }

    private var scale: CGFloat { fitScale * zoom }

    public var displayedFrame: CGRect {
        let width = CGFloat(remote.width) * scale
        let height = CGFloat(remote.height) * scale
        return CGRect(
            x: container.width / 2 + offset.x - width / 2,
            y: container.height / 2 + offset.y - height / 2,
            width: width,
            height: height
        )
    }

    public func remotePoint(forViewPoint point: CGPoint, clampingToFrame: Bool = false) -> CGPoint? {
        let frame = displayedFrame
        guard scale > 0 else { return nil }
        if !clampingToFrame && !frame.contains(point) { return nil }
        let x = min(max((point.x - frame.minX) / scale, 0), CGFloat(remote.width - 1))
        let y = min(max((point.y - frame.minY) / scale, 0), CGFloat(remote.height - 1))
        return CGPoint(x: x, y: y)
    }

    public func viewPoint(forRemote point: CGPoint) -> CGPoint {
        let frame = displayedFrame
        return CGPoint(x: frame.minX + point.x * scale, y: frame.minY + point.y * scale)
    }

    public mutating func pinch(by factor: CGFloat, around focal: CGPoint) {
        guard factor.isFinite, factor > 0, scale > 0 else { return }
        let frame = displayedFrame
        let anchorX = (focal.x - frame.minX) / scale
        let anchorY = (focal.y - frame.minY) / scale
        zoom = min(max(zoom * factor, Self.minimumZoom), Self.maximumZoom)
        let newScale = scale
        offset = CGPoint(
            x: focal.x - container.width / 2 - (anchorX - CGFloat(remote.width) / 2) * newScale,
            y: focal.y - container.height / 2 - (anchorY - CGFloat(remote.height) / 2) * newScale
        )
        clampOffset()
    }

    public mutating func pan(by delta: CGPoint) {
        offset = CGPoint(x: offset.x + delta.x, y: offset.y + delta.y)
        clampOffset()
    }

    public mutating func reset() {
        zoom = Self.minimumZoom
        offset = .zero
    }

    public mutating func update(container: CGSize, remote: RFBSize) {
        self.container = container
        if self.remote != remote {
            self.remote = remote
            reset()
        }
        clampOffset()
    }

    private mutating func clampOffset() {
        let width = CGFloat(remote.width) * scale
        let height = CGFloat(remote.height) * scale
        let limitX = max(0, (width - container.width) / 2)
        let limitY = max(0, (height - container.height) / 2)
        offset = CGPoint(x: min(max(offset.x, -limitX), limitX), y: min(max(offset.y, -limitY), limitY))
    }
}
