import Foundation
import PalProtocol

public struct DeviceMcpChannel: Sendable {
    public let id: UUID
    public let deliver: @Sendable (_ relayID: String, _ message: JSONValue) async -> Bool
    public let fail: @Sendable (_ relayID: String, _ code: DeviceMcpFailCode, _ message: String) async -> Void

    public init(
        id: UUID = UUID(),
        deliver: @escaping @Sendable (_ relayID: String, _ message: JSONValue) async -> Bool,
        fail: @escaping @Sendable (_ relayID: String, _ code: DeviceMcpFailCode, _ message: String) async -> Void
    ) {
        self.id = id
        self.deliver = deliver
        self.fail = fail
    }
}

public protocol DeviceMcpRelay: Sendable {
    func activeServers() async -> [DeviceMcpServer]
    func relay(_ frame: DeviceMcpFrame, over channel: DeviceMcpChannel) async
    func close(_ close: DeviceMcpClose) async
    func channelEnded(_ id: UUID) async
}
