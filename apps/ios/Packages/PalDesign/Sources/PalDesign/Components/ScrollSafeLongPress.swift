#if os(iOS)
import SwiftUI
import UIKit

public struct ScrollSafeLongPress: UIGestureRecognizerRepresentable {
    private let minimumDuration: TimeInterval
    private let perform: @MainActor () -> Void

    public init(minimumDuration: TimeInterval = 0.35, perform: @escaping @MainActor () -> Void) {
        self.minimumDuration = minimumDuration
        self.perform = perform
    }

    public func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = minimumDuration
        press.numberOfTouchesRequired = 1
        return press
    }

    public func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        if recognizer.state == .began { perform() }
    }
}
#endif
