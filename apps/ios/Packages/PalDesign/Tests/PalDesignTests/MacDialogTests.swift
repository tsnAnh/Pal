@testable import PalDesign
import Testing

@MainActor
@Suite("Mac alert and confirmation wiring")
struct MacDialogTests {
    final class Log {
        var ran: [String] = []
        var dismissals = 0
    }

    private func request(_ log: Log, roles: [(String, MacDialogRole)]) -> MacDialogRequest {
        let actions = roles.map { title, role in MacDialogAction(title, role: role) { log.ran.append(title) } }
        return MacDialogRequest(id: .init(), content: MacDialogContent("Delete?", message: "It can't be undone.", actions: actions)) {
            log.dismissals += 1
        }
    }

    @Test func returnRunsTheFirstPlainActionAndDismisses() {
        let log = Log()
        request(log, roles: [("Delete", .destructive), ("Keep", .plain), ("Cancel", .cancel)]).press(.returnKey)
        #expect(log.ran == ["Keep"])
        #expect(log.dismissals == 1)
    }

    @Test func returnNeverRunsADestructiveActionWhenThereIsAnotherChoice() {
        let log = Log()
        request(log, roles: [("Delete", .destructive), ("Cancel", .cancel)]).press(.returnKey)
        #expect(log.ran == ["Cancel"])
    }

    @Test func escapeRunsTheCancelActionAndDismisses() {
        let log = Log()
        request(log, roles: [("Delete", .destructive), ("Cancel", .cancel)]).press(.escape)
        #expect(log.ran == ["Cancel"])
        #expect(log.dismissals == 1)
    }

    @Test func escapeWithoutACancelActionStillDismissesAndRunsNothing() {
        let log = Log()
        request(log, roles: [("Remove", .destructive)]).press(.escape)
        #expect(log.ran.isEmpty)
        #expect(log.dismissals == 1)
    }

    @Test func aSingleDestructiveActionIsNeverTheReturnDefault() {
        let log = Log()
        request(log, roles: [("Remove", .destructive)]).press(.returnKey)
        #expect(log.ran.isEmpty)
        #expect(log.dismissals == 1)
    }

    @Test func tappingADestructiveActionRunsItOnceAndDismisses() {
        let log = Log()
        let dialog = request(log, roles: [("Delete", .destructive), ("Cancel", .cancel)])
        let delete = dialog.content.actions[0]
        #expect(delete.role == .destructive)
        dialog.activate(delete)
        #expect(log.ran == ["Delete"])
        #expect(log.dismissals == 1)
    }

    @Test func theCancelActionIsShownFirstAndTheRestKeepTheirOrder() {
        let dialog = request(Log(), roles: [("Delete", .destructive), ("Archive", .plain), ("Cancel", .cancel)])
        #expect(dialog.content.displayOrder.map(\.title) == ["Cancel", "Delete", "Archive"])
    }

    @Test func theCenterShowsRequestsInOrderAndForgetsWithdrawnOnes() {
        let center = MacDialogCenter()
        let log = Log()
        let first = request(log, roles: [("A", .plain)])
        let second = request(log, roles: [("B", .plain)])
        center.present(first)
        center.present(second)
        #expect(center.current?.id == first.id)
        center.withdraw(first.id)
        #expect(center.current?.id == second.id)
        center.withdraw(second.id)
        #expect(center.current == nil)
    }

    @Test func presentingTheSameRequestTwiceKeepsOneEntry() {
        let center = MacDialogCenter()
        let first = request(Log(), roles: [("A", .plain)])
        center.present(first)
        center.present(first)
        #expect(center.queue.count == 1)
    }
}
