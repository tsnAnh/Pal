import CoreGraphics
import Foundation

public struct PhotoCrop: Equatable, Sendable {
    public static let zoomRange = 1.0...4.0

    public private(set) var zoom: Double
    public private(set) var center: CGPoint

    public init() {
        zoom = Self.zoomRange.lowerBound
        center = CGPoint(x: 0.5, y: 0.5)
    }

    public static func side(zoom: Double, in size: CGSize) -> CGFloat {
        min(size.width, size.height) / CGFloat(zoom)
    }

    public func sourceRect(in size: CGSize) -> CGRect {
        let side = Self.side(zoom: zoom, in: size)
        let x = min(max(center.x * size.width - side / 2, 0), size.width - side)
        let y = min(max(center.y * size.height - side / 2, 0), size.height - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    public func zoomed(to value: Double, in size: CGSize) -> PhotoCrop {
        guard value.isFinite else { return self }
        var next = self
        next.zoom = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        return next.settled(in: size)
    }

    public func moved(byPoints delta: CGSize, circle: CGFloat, in size: CGSize) -> PhotoCrop {
        guard circle > 0, size.width > 0, size.height > 0, delta.width.isFinite, delta.height.isFinite else { return self }
        let rect = sourceRect(in: size)
        let pixelsPerPoint = rect.width / circle
        var next = self
        next.center = CGPoint(
            x: (rect.midX - delta.width * pixelsPerPoint) / size.width,
            y: (rect.midY - delta.height * pixelsPerPoint) / size.height
        )
        return next.settled(in: size)
    }

    private func settled(in size: CGSize) -> PhotoCrop {
        let rect = sourceRect(in: size)
        var next = self
        next.center = CGPoint(x: rect.midX / size.width, y: rect.midY / size.height)
        return next
    }
}
