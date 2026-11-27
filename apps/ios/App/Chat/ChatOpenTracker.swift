import PalChat

@MainActor
final class ChatOpenTracker {
    var meter = ChatOpenSettleMeter()
    var lastEventAt = ContinuousClock.now
    var quietTask: Task<Void, Never>?
    var tailExtensionScheduled = false
    var reported = false
    var textScale = ""
    private let openedAt = ContinuousClock.now

    var elapsedMilliseconds: Int { Int(openedAt.duration(to: .now) / .milliseconds(1)) }
}
