import PalProtocol

extension GatewayConnection {
    public func call(_ method: String, params: JSONValue? = nil, timeout: Duration? = nil) async throws -> JSONValue {
        let trace = TraceID.random()
        do {
            return try await send(method, params: params, timeout: timeout, trace: trace)
        } catch let error as GatewayTransportError {
            if let faults, method != Self.reportMethod, let fault = Self.fault(error, method: method, trace: trace) {
                await faults.record(fault)
            }
            throw error
        }
    }

    public static let reportMethod = "diag.report"

    static func fault(_ error: GatewayTransportError, method: String, trace: TraceID) -> GatewayFault? {
        switch error {
        case .rpc(let rpc): GatewayFault(rpc, method: method)
        case .timedOut: .transport("timeout", method: method, trace: trace)
        case .closed: .transport("offline", method: method, trace: trace)
        default: nil
        }
    }

    public func ping() async throws {
        let result = try await call("gateway.ping", timeout: .seconds(10))
        guard result["ok"]?.boolValue == true else { throw GatewayTransportError.unexpectedFirstFrame }
    }
}
