import Observation
import SwiftUI
import Synchronization
import Testing

@testable import HermesBots

@MainActor
@Suite("Chat scroll position writes")
struct ChatScrollControllerTests {
    private final class Fired: Sendable {
        private let storage = Mutex(false)
        var value: Bool { storage.withLock { $0 } }
        func mark() { storage.withLock { $0 = true } }
    }

    private func positionNotified(_ controller: ChatScrollController, _ body: () -> Void) -> Bool {
        let fired = Fired()
        withObservationTracking { _ = controller.position } onChange: { fired.mark() }
        body()
        return fired.value
    }

    private func viewport(distanceFromNewest: CGFloat) -> ChatViewport {
        ChatViewport(distanceFromNewest: distanceFromNewest, distanceFromOldest: 4000, viewportHeight: 600, contentHeight: 5000)
    }

    private func readingController() -> ChatScrollController {
        let controller = ChatScrollController()
        controller.observe(viewport(distanceFromNewest: 0))
        controller.observe(.interacting)
        controller.observe(viewport(distanceFromNewest: 300))
        controller.observe(.idle)
        controller.visibleRowsChanged(["anchor"])
        controller.rowMoved("anchor", contentMinY: 100)
        return controller
    }

    @Test("following at the newest edge never writes the position")
    func atNewestEdgeSkipsWrites() {
        let controller = ChatScrollController()
        controller.observe(viewport(distanceFromNewest: 0))
        let notified = positionNotified(controller) {
            controller.contentGrew()
            controller.contentGrew()
            controller.rowsChanged(["a", "b"])
        }
        #expect(!notified)
    }

    @Test("an off-newest chat writes once and stays quiet after the scroll view reports the newest edge")
    func writesOnceThenConverges() {
        let controller = ChatScrollController()
        controller.position = ScrollPosition(idType: String.self, y: 120)
        controller.observe(viewport(distanceFromNewest: 120))
        #expect(positionNotified(controller) { controller.contentGrew() })
        #expect(controller.position.edge == .top)
        controller.observe(viewport(distanceFromNewest: 0))
        let afterConverging = positionNotified(controller) {
            controller.contentGrew()
            controller.contentGrew()
        }
        #expect(!afterConverging)
    }

    @Test("a hidden chat defers bookkeeping and resyncs once when shown")
    func hiddenChatDefersUntilShown() {
        let controller = ChatScrollController()
        controller.position = ScrollPosition(idType: String.self, y: 120)
        controller.observe(viewport(distanceFromNewest: 120))
        controller.setVisible(false, rowIDs: [])
        let whileHidden = positionNotified(controller) {
            controller.contentGrew()
            controller.contentGrew()
            controller.rowsChanged(["a"])
        }
        #expect(!whileHidden)
        #expect(positionNotified(controller) { controller.setVisible(true, rowIDs: ["a"]) })
        #expect(controller.position.edge == .top)
    }

    @Test("rows that arrive while hidden count as unseen once shown in reading mode")
    func hiddenRowsAreCountedOnResume() {
        let controller = readingController()
        controller.rowsChanged(["a"])
        controller.setVisible(false, rowIDs: ["a"])
        controller.rowsChanged(["a", "b", "c"])
        #expect(controller.unseen == 0)
        controller.setVisible(true, rowIDs: ["a", "b", "c"])
        #expect(controller.unseen == 2)
    }

    @Test("anchor moves while hidden apply as one write when shown")
    func anchorDriftAppliesOnResume() {
        let controller = readingController()
        controller.setVisible(false, rowIDs: [])
        let whileHidden = positionNotified(controller) {
            controller.rowMoved("anchor", contentMinY: 140)
            controller.rowMoved("anchor", contentMinY: 170)
        }
        #expect(!whileHidden)
        #expect(positionNotified(controller) { controller.setVisible(true, rowIDs: []) })
        #expect(controller.position.y == 370)
    }

    @Test("an open that drifts off the newest edge pins it once, then hands the edge anchor back")
    func openDriftPinsOnce() {
        let controller = ChatScrollController()
        controller.observe(viewport(distanceFromNewest: 0), tracksOpen: true)
        controller.observe(viewport(distanceFromNewest: 36.5), tracksOpen: true)
        #expect(controller.position.y == 0)
        controller.observe(viewport(distanceFromNewest: 0), tracksOpen: true)
        #expect(controller.position.edge == .top)
        let afterwards = positionNotified(controller) {
            controller.observe(viewport(distanceFromNewest: 36.5), tracksOpen: true)
        }
        #expect(!afterwards)
    }

    @Test("drift is left alone outside the open window and while reading")
    func driftOutsideOpenIsNotPinned() {
        let following = ChatScrollController()
        following.observe(viewport(distanceFromNewest: 0))
        #expect(!positionNotified(following) { following.observe(viewport(distanceFromNewest: 36.5)) })
        let reading = readingController()
        #expect(!positionNotified(reading) { reading.observe(viewport(distanceFromNewest: 300), tracksOpen: true) })
    }
}
