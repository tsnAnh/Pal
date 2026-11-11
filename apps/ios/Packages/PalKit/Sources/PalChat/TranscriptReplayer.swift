import Foundation
import PalProtocol
import PalTransport

public struct TranscriptReplayer: Sendable {
    public private(set) var transcript = Transcript()
    private var pendingMethods: [RPCID: String] = [:]

    public init() {}

    public mutating func feed(_ direction: FrameDirection, _ message: RPCMessage) {
        switch (direction, message) {
        case (.outbound, .request(let request)):
            pendingMethods[request.id] = request.method
            guard request.method == "prompt.submit",
                  let params = request.params,
                  params["display_kind"]?.stringValue != "hidden",
                  let submissionID = params["submission_id"]?.stringValue,
                  let text = params["text"]?.stringValue
            else { return }
            transcript.echoUser(submissionID: submissionID, text: text)
        case (.inbound, .notification(let notification)):
            guard let event = GatewayEvent(notification: notification) else { return }
            _ = transcript.apply(SessionEventFrame(event))
        case (.inbound, .response(let response)):
            guard let id = response.id, let method = pendingMethods.removeValue(forKey: id), let result = response.result else {
                return
            }
            ingest(method: method, result: result)
        default:
            return
        }
    }

    private mutating func ingest(method: String, result: JSONValue) {
        switch method {
        case "session.create", "session.resume":
            guard let snapshot = try? result.decoded(as: SessionSnapshot.self) else { return }
            _ = transcript.reconcile(with: snapshot)
        case "session.events.since":
            guard let since = try? result.decoded(as: EventsSinceResult.self) else { return }
            if since.snapshotRequired {
                transcript.requestResync()
                return
            }
            for raw in since.events {
                guard let event = GatewayEvent(params: raw) else { continue }
                if case .resyncRequired = transcript.apply(SessionEventFrame(event)) { break }
            }
        default:
            return
        }
    }
}
