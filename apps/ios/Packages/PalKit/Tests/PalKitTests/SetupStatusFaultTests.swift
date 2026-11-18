import Foundation
import PalConnect
import PalProtocol
import Testing

@Suite("Setup status from a gateway fault")
struct SetupStatusFaultTests {
    @Test func aGatewayFaultFillsTheDetailsWithoutLeakingIntoTheSentence() throws {
        let fault = GatewayFault(
            code: 4030, reason: "forbidden", trace: try #require(TraceID("gj43o07j")), method: "mcp.servers.add",
            source: .gateway, gatewayVersion: "bbf2401c"
        )
        let status = SetupStatus(fault: fault, subject: "Notion")
        #expect(status.kind == .forbidden)
        #expect(status.method == "mcp.servers.add")
        #expect(status.trace == "gj43o07j")
        #expect(status.gatewayVersion == "bbf2401c")
        #expect(!status.reason.contains("gj43o07j"))
    }
}
