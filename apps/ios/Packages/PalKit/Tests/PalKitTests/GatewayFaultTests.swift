import Foundation
import PalBotProfile
@testable import PalConnect
import PalDiagnostics
import PalProtocol
import PalTransport
import Testing

struct GatewayFaultTests {
    private let refusal = RPCError(code: 4403, message: "Only the owner can set up chat apps", data: .object([
        "reason": .string("owner_only"), "trace": .string("7f3k2m9a"), "gateway_version": .string("291aaa2b"),
    ]))

    @Test func aTraceIsEightLowercaseAlphanumerics() {
        let traces = (0..<50).map { _ in TraceID.random().rawValue }
        #expect(traces.allSatisfy { $0.count == 8 && TraceID($0) != nil })
        #expect(Set(traces).count > 1)
        #expect(TraceID("UPPER") == nil && TraceID("") == nil && TraceID(String(repeating: "a", count: 17)) == nil)
    }

    @Test func everyRequestFrameCarriesATopLevelTraceAndLeavesParamsAlone() throws {
        let trace = TraceID.random()
        let data = try RPCCodec.encode(RPCRequest(id: .int(1), method: "chat.provider.list", params: ["profile": "pal"], trace: trace))
        let frame = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(frame["trace"]?.stringValue == trace.rawValue)
        #expect(frame["params"] == ["profile": "pal"])
    }

    @Test func aGatewayErrorFrameBecomesAFaultWithCodeReasonAndTrace() throws {
        let data = #"{"reason":"owner_only","trace":"7f3k2m9a","gateway_version":"291aaa2b"}"#
        let frame = Data(#"{"jsonrpc":"2.0","id":1,"trace":"7f3k2m9a","error":{"code":4403,"message":"x","data":\#(data)}}"#.utf8)
        guard case .response(let response) = try RPCCodec.decode(frame), let rpc = response.error else {
            Issue.record("not an error response")
            return
        }
        let fault = GatewayFault(rpc, method: "chat.provider.list")
        #expect(fault == GatewayFault(code: 4403, reason: "owner_only", trace: TraceID("7f3k2m9a")!, method: "chat.provider.list",
                                      source: .gateway, gatewayVersion: "291aaa2b"))
        #expect(fault.detailsLine == "owner_only, trace 7f3k2m9a, gateway 291aaa2b")
    }

    @Test func chatInstallErrorsExposeTheFaultForGatewayTransportAndDecodeFailures() {
        let refused = ChatInstallClientError(GatewayTransportError.rpc(refusal), method: "chat.install.status")
        #expect(refused.reason == .forbidden)
        #expect(refused.fault?.trace.rawValue == "7f3k2m9a" && refused.fault?.reason == "owner_only" && refused.fault?.code == 4403)
        let offline = ChatInstallClientError(GatewayTransportError.closed(.lost), method: "chat.spaces.list")
        #expect(offline.isUnreachable && offline.reason == .offline)
        #expect(offline.fault?.source == .transport && offline.fault?.reason == "offline" && offline.fault?.method == "chat.spaces.list")
        let timedOut = ChatInstallClientError(GatewayTransportError.timedOut, method: "chat.install.begin")
        #expect(timedOut.isUnreachable && timedOut.fault?.reason == "timeout")
        let undecodable = ChatInstallClientError.decode(method: "chat.install.status")
        #expect(undecodable.reason == .decode && undecodable.fault?.source == .decode)
        #expect(undecodable.fault?.method == "chat.install.status" && undecodable.fault?.reason == "decode")
        #expect(ChatInstallClientError(GatewayTransportError.rpc(RPCError(code: -32601, message: "x")), method: "chat.provider.list") == .unsupported)
    }

    @Test func connectAppsErrorsExposeTheGatewayFault() {
        let error = ConnectAppsService.map(.rpc(refusal), method: "connectors.connect")
        #expect(error.fault?.trace.rawValue == "7f3k2m9a" && error.fault?.method == "connectors.connect")
        #expect(ConnectAppsService.map(.timedOut).fault == nil)
    }

    @Test func aDiagnosticLineCarriesItsTrace() {
        #expect(DiagnosticEvent(level: .debug, category: "ws", message: "rpc refused", trace: "7f3k2m9a").line == "trace=7f3k2m9a rpc refused")
        #expect(DiagnosticEvent(level: .debug, category: "ws", message: "connected").line == "connected")
    }
}
