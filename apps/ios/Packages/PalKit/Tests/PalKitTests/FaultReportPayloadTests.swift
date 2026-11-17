import Foundation
import PalClient
import PalProtocol
import PalTransport
import Synchronization
import Testing

private final class Attempts: Sendable {
    let count = Mutex(0)
}

@Suite("diag.report payloads")
struct FaultReportPayloadTests {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/diag-report/app-payloads.json")

    private static func payload(_ fault: GatewayFault) -> JSONValue {
        FaultReporter.params(FaultRecord(fault, at: Date(timeIntervalSince1970: 0)))
    }

    @Test func theAppSendsExactlyThePayloadsTheGatewayTestRecords() throws {
        let expected = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: Self.fixture))
        let sent: [String: JSONValue] = [
            "offline": Self.payload(.transport("offline", method: "gateway.ping", trace: TraceID("restart1")!)),
            "timeout": Self.payload(.transport("timeout", method: "kanban.events.since", trace: TraceID("restart2")!)),
            "decode": Self.payload(.decode(method: "kanban.board.snapshot", trace: TraceID("restart3")!)),
        ]
        #expect(sent == expected)
    }

    @Test func aGatewayMismatchIsNeverReportedBecauseTheGatewayAlreadyLoggedIt() {
        let rpc = RPCError(code: 4001, message: "gateway_mismatch", data: ["reason": "gateway_mismatch", "trace": "8lsyzf94"])
        #expect(FaultRecord(GatewayFault(rpc, method: "kanban.events.since"), at: Date()).reportable == false)
    }

    @Test func aReportTheGatewayRefusesIsDroppedNotResent() async {
        let store = FaultStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("faults-\(UUID().uuidString).json"))
        await store.record(.transport("offline", method: "gateway.ping"))
        let attempts = Attempts()
        let refuse: FaultReporter.Call = { _, _ in
            attempts.count.withLock { $0 += 1 }
            throw GatewayTransportError.rpc(RPCError(code: 4000, message: "invalid params: method", data: ["reason": "invalid_params"]))
        }
        await FaultReporter.flush(store, call: refuse)
        await FaultReporter.flush(store, call: refuse)
        #expect(attempts.count.withLock { $0 } == 1)
        #expect(await store.pendingReports().isEmpty)
    }
}
