import Foundation
import PalProtocol
import PalTransport

public enum FaultReporter {
    public typealias Call = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue

    public static func params(_ record: FaultRecord) -> JSONValue {
        var params: [String: JSONValue] = [
            "trace": .string(record.trace), "source": .string(record.source),
            "reason": .string(record.reason), "method": .string(record.method),
        ]
        if let code = record.code { params["code"] = .int(code) }
        return .object(params)
    }

    public static func flush(_ store: FaultStore, call: Call) async {
        var settled: Set<String> = []
        for record in await store.pendingReports() {
            guard !Task.isCancelled else { break }
            do {
                _ = try await call(GatewayConnection.reportMethod, params(record))
                settled.insert(record.id)
            } catch GatewayTransportError.rpc {
                settled.insert(record.id)
            } catch {
                break
            }
        }
        await store.markReported(settled)
    }
}
