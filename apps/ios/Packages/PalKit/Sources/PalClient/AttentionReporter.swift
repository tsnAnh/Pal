import Foundation

@MainActor
public protocol AppActivity: AnyObject {
    var isFrontmost: Bool { get }
    func observe(_ handler: @escaping @MainActor () -> Void)
}

@MainActor
public final class AttentionReporter {
    private let activity: (any AppActivity)?
    private let report: @MainActor (ReachAttention) -> Void
    private var sceneIsActive = false

    public init(activity: (any AppActivity)?, report: @escaping @MainActor (ReachAttention) -> Void) {
        self.activity = activity
        self.report = report
        activity?.observe { [weak self] in self?.publish() }
    }

    public func sceneChanged(isActive: Bool) {
        sceneIsActive = isActive
        publish()
    }

    private func publish() {
        report(ReachAttention(sceneIsActive: sceneIsActive && (activity?.isFrontmost ?? true)))
    }
}
