import PalClient
import Testing

@MainActor
private final class FakeAppActivity: AppActivity {
    var isFrontmost: Bool
    private var handler: (@MainActor () -> Void)?

    init(isFrontmost: Bool) {
        self.isFrontmost = isFrontmost
    }

    func observe(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func change(isFrontmost: Bool) {
        self.isFrontmost = isFrontmost
        handler?()
    }
}

@MainActor
private final class Reports {
    var sent: [ReachAttention] = []
}

@Suite("Attention reporter")
@MainActor
struct AttentionReporterTests {
    private func make(activity: (any AppActivity)?) -> (AttentionReporter, Reports) {
        let reports = Reports()
        return (AttentionReporter(activity: activity) { reports.sent.append($0) }, reports)
    }

    @Test func anActiveSceneInAnAppThatIsNotFrontmostReportsBackground() {
        let (reporter, reports) = make(activity: FakeAppActivity(isFrontmost: false))
        reporter.sceneChanged(isActive: true)
        #expect(reports.sent == [.background])
    }

    @Test func foregroundNeedsAnActiveSceneAndTheFrontmostApp() {
        let (reporter, reports) = make(activity: FakeAppActivity(isFrontmost: true))
        reporter.sceneChanged(isActive: false)
        reporter.sceneChanged(isActive: true)
        #expect(reports.sent == [.background, .foreground])
    }

    @Test func resigningTheAppReportsBackgroundWhileTheSceneStaysActive() {
        let activity = FakeAppActivity(isFrontmost: true)
        let (reporter, reports) = make(activity: activity)
        reporter.sceneChanged(isActive: true)
        activity.change(isFrontmost: false)
        activity.change(isFrontmost: true)
        #expect(reports.sent == [.foreground, .background, .foreground])
    }

    @Test func withoutAnAppActivitySourceTheSceneDecides() {
        let (reporter, reports) = make(activity: nil)
        reporter.sceneChanged(isActive: true)
        reporter.sceneChanged(isActive: false)
        #expect(reports.sent == [.foreground, .background])
    }
}
