import PalProtocol
import PalTransport

extension ChatSession {
    func serveClarifyRequest(_ request: RPCRequest) -> Bool {
        guard request.method == PendingPrompt.clarifyRequestMethod, case .string(let requestID) = request.id,
              let prompt = PendingPrompt.clarifyBatch(requestID: requestID, params: request.params, sessionID: transcript.sessionID)
        else { return false }
        transcript.addCard(prompt)
        timeline.addServerClarify(prompt)
        publishLive()
        return true
    }

    func rejectServerRequest(_ request: RPCRequest, on connection: GatewayConnection) async {
        diagnostics.debug("chat", "rejected server request \(request.method)")
        await connection.reject(request.id, code: -32601, message: "unsupported")
    }

    public func answerClarifyForm(_ prompt: PendingPrompt, answers: [(qid: String, answer: ClarifyForm.Answer)]) async throws {
        guard case .live = phase, let api else { throw ChatError.notConnected }
        for entry in answers {
            switch entry.answer {
            case .answered(let text): try await api.lockClarify(requestID: prompt.promptID, questionID: entry.qid, answer: text)
            case .skipped: try await api.lockClarify(requestID: prompt.promptID, questionID: entry.qid, answer: nil)
            }
        }
    }
}
