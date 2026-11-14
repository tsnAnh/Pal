import Foundation
import PalClient
import PalProtocol
import PalTransport

extension SessionAPI {
    public var supportsTimeline: Bool {
        RuntimeDescription.supports(TimelineWire.capability, advertised: connection.negotiatedRuntime)
    }

    public func resumeTimeline(sessionID: String, messageLimit: Int?, timelineLimit: Int) async throws -> TimelineResume {
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let messageLimit, supportsHistoryPaging { params["message_limit"] = .int(messageLimit) }
        if supportsTimeline {
            params[TimelineWire.resumeLimitParam] = .int(timelineLimit)
            params["omit_messages"] = .bool(true)
        }
        let result = try await call("session.resume", params)
        return try decode(TimelineResume.self, result, "session.resume")
    }

    public func timelinePage(sessionID: String, before: String?, limit: Int) async throws -> TimelinePageWire {
        var params: [String: JSONValue] = ["session_id": .string(sessionID), TimelineWire.limitParam: .int(limit)]
        if let before { params[TimelineWire.beforeParam] = .string(before) }
        let result = try await call(TimelineWire.pageMethod, params)
        return try decode(TimelinePageWire.self, result, TimelineWire.pageMethod)
    }
}

extension GatewayTransportError {
    var isCursorStale: Bool {
        guard case .rpc(let rpc) = self else { return false }
        return rpc.data?["reason"]?.stringValue == TimelineWire.cursorStaleReason || rpc.message == TimelineWire.cursorStaleReason
    }
}
