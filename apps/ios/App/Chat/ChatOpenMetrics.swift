import Foundation
import Synchronization

enum ChatOpenMetrics {
    struct Snapshot: Codable, Equatable {
        var rowsLaidOut = 0
        var rowBodies = 0
        var listBodies = 0
        var geometryEvents = 0
        var positionWrites = 0
    }

    private struct State {
        var snapshot = Snapshot()
        var laidOut: Set<String> = []
    }

    nonisolated(unsafe) static var isOn = ProcessInfo.processInfo.environment[ChatScrollTrace.environmentKey] == "1"

    private static let state = Mutex(State())

    static var snapshot: Snapshot { state.withLock { $0.snapshot } }

    static func reset() {
        state.withLock { $0 = State() }
    }

    static func rowLaidOut(_ id: String) {
        guard isOn else { return }
        state.withLock { if $0.laidOut.insert(id).inserted { $0.snapshot.rowsLaidOut += 1 } }
    }

    static func rowBody() {
        guard isOn else { return }
        state.withLock { $0.snapshot.rowBodies += 1 }
    }

    static func listBody() {
        guard isOn else { return }
        state.withLock { $0.snapshot.listBodies += 1 }
    }

    static func geometry() {
        guard isOn else { return }
        state.withLock { $0.snapshot.geometryEvents += 1 }
    }

    static func positionWrite() {
        guard isOn else { return }
        state.withLock { $0.snapshot.positionWrites += 1 }
    }
}
