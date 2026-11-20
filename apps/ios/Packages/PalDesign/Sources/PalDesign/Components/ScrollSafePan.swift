#if os(iOS)
import SwiftUI
import UIKit

public struct ScrollSafePan: UIGestureRecognizerRepresentable {
    public struct Sample: Sendable {
        public let translation: CGSize
        public let velocity: CGSize
    }

    public enum Phase: Sendable {
        case changed(Sample)
        case ended(Sample)
        case cancelled
    }

    private let begins: @MainActor (_ start: CGPoint, _ velocity: CGSize) -> Bool
    private let update: @MainActor (Phase) -> Void

    public init(
        begins: @escaping @MainActor (_ start: CGPoint, _ velocity: CGSize) -> Bool,
        update: @escaping @MainActor (Phase) -> Void
    ) {
        self.begins = begins
        self.update = update
    }

    public func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(begins: begins)
    }

    public func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    public func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.begins = begins
    }

    public func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let window = recognizer.view?.window
        let translation = recognizer.translation(in: window)
        let velocity = recognizer.velocity(in: window)
        let sample = Sample(
            translation: CGSize(width: translation.x, height: translation.y),
            velocity: CGSize(width: velocity.x, height: velocity.y)
        )
        switch recognizer.state {
        case .began, .changed: update(.changed(sample))
        case .ended: update(.ended(sample))
        case .cancelled, .failed: update(.cancelled)
        default: break
        }
    }

    @MainActor
    public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var begins: @MainActor (CGPoint, CGSize) -> Bool

        init(begins: @escaping @MainActor (CGPoint, CGSize) -> Bool) {
            self.begins = begins
        }

        public func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let window = pan.view?.window
            let location = pan.location(in: window)
            let translation = pan.translation(in: window)
            let velocity = pan.velocity(in: window)
            return begins(
                CGPoint(x: location.x - translation.x, y: location.y - translation.y),
                CGSize(width: velocity.x, height: velocity.y)
            )
        }
    }
}
#endif
