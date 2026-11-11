import Foundation
import HermesChat
import HermesProtocol
import Testing

@Suite("Image generation tool results")
struct ImageGenerationTests {
    private static let success = """
    {"success": true, "image": "/tmp/cache/out.png", "host_image": "/Users/me/cache/out.png", "agent_visible_image": "/work/out.png", "pixel_size": "1024x1024"}
    """

    private func frame(_ type: String, _ payload: JSONValue, seq: Int) -> SessionEventFrame {
        SessionEventFrame(event: SessionEvent(type: type, payload: payload), sessionID: "s1", seq: seq, replayEpoch: "e1")
    }

    private func liveTranscript() throws -> Transcript {
        var transcript = Transcript()
        let snapshot: JSONValue = ["session_id": "s1", "messages": [], "replay_epoch": "e1", "last_sequence": 0]
        _ = transcript.reconcile(with: try snapshot.decoded(as: SessionSnapshot.self))
        return transcript
    }

    private func history(_ rows: [JSONValue]) throws -> Transcript {
        var transcript = Transcript()
        let snapshot: JSONValue = ["session_id": "s1", "messages": .array(rows), "replay_epoch": "e1", "last_sequence": 0]
        transcript.load(try snapshot.decoded(as: SessionSnapshot.self))
        return transcript
    }

    private func generations(_ transcript: Transcript) -> [ImageGeneration] {
        transcript.items.compactMap { item in
            if case .tool(let call) = item.content { return call.imageGeneration }
            return nil
        }
    }

    @Test func runningCallShowsPlaceholderWithPromptAndShape() throws {
        var transcript = try liveTranscript()
        _ = transcript.apply(frame("tool.start", ["tool_id": "t1", "name": "image_generate", "args": ["prompt": "a red fox\nin snow", "aspect_ratio": "portrait"]], seq: 1))
        #expect(generations(transcript) == [.generating(prompt: "a red fox in snow", shape: .portrait)])
    }

    @Test func unknownAspectHintFallsBackToLandscape() {
        #expect(ImageGeneration.Shape(hint: nil) == .landscape)
        #expect(ImageGeneration.Shape(hint: " Square ") == .square)
        #expect(ImageGeneration.Shape(hint: "wide") == .landscape)
    }

    @Test func longPromptIsTrimmedForTheSummary() {
        let summary = ImageGeneration.summary(of: String(repeating: "a", count: 400))
        #expect(summary?.count == 161)
        #expect(ImageGeneration.summary(of: "  \n ") == nil)
    }

    @Test func completionWithObjectResultBecomesTheImagePreferringHostPath() throws {
        var transcript = try liveTranscript()
        _ = transcript.apply(frame("tool.start", ["tool_id": "t1", "name": "image_generate", "args": ["prompt": "fox"]], seq: 1))
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(Self.success.utf8))
        _ = transcript.apply(frame("tool.complete", ["tool_id": "t1", "name": "image_generate", "result": result], seq: 2))
        #expect(generations(transcript) == [.ready(ImageReference(source: .hostPath("/Users/me/cache/out.png")))])
        #expect(transcript.items.count == 1)
    }

    @Test func completionWithStringResultBecomesTheImage() throws {
        var transcript = try liveTranscript()
        _ = transcript.apply(frame("tool.complete", ["tool_id": "t1", "name": "image_generate", "result": .string(Self.success)], seq: 1))
        #expect(generations(transcript) == [.ready(ImageReference(source: .hostPath("/Users/me/cache/out.png")))])
    }

    @Test func remoteAndInlineSourcesAreRecognised() throws {
        let remote: JSONValue = ["success": true, "image": "https://cdn.example.com/a/render"]
        #expect(ImageGeneration.resolve(status: .finished, prompt: nil, aspectRatio: nil, result: remote)
            == .ready(ImageReference(source: .remote(URL(string: "https://cdn.example.com/a/render")!))))
        let bytes = Data([0x89, 0x50, 0x4e, 0x47])
        let inline: JSONValue = ["success": true, "image": .string("data:image/png;base64," + bytes.base64EncodedString())]
        #expect(ImageGeneration.resolve(status: .finished, prompt: nil, aspectRatio: nil, result: inline)
            == .ready(ImageReference(source: .inline(bytes))))
    }

    @Test func reportedFailureShowsTheReason() throws {
        var transcript = try liveTranscript()
        _ = transcript.apply(frame("tool.start", ["tool_id": "t1", "name": "image_generate"], seq: 1))
        _ = transcript.apply(frame("tool.complete", ["tool_id": "t1", "name": "image_generate", "result": ["success": false, "image": .null, "error": "Content policy blocked the request"]], seq: 2))
        #expect(generations(transcript) == [.failed(reason: "Content policy blocked the request")])
    }

    @Test func failureWithoutAReasonStillShowsPlainText() {
        let result: JSONValue = ["success": false, "image": .null]
        #expect(ImageGeneration.resolve(status: .finished, prompt: nil, aspectRatio: nil, result: result) == .failed(reason: ImageGeneration.genericFailure))
        let noImage: JSONValue = ["success": true]
        #expect(ImageGeneration.resolve(status: .finished, prompt: nil, aspectRatio: nil, result: noImage) == .failed(reason: ImageGeneration.genericFailure))
    }

    @Test func turnEndingWhileRunningBecomesAFailureNotAnEmptyGap() throws {
        var transcript = try liveTranscript()
        _ = transcript.apply(frame("tool.start", ["tool_id": "t1", "name": "image_generate", "args": ["prompt": "fox"]], seq: 1))
        _ = transcript.apply(frame("message.complete", ["text": "Sorry"], seq: 2))
        #expect(generations(transcript) == [.failed(reason: ImageGeneration.stoppedReason)])
    }

    @Test func otherToolsAreNotImageGenerations() throws {
        var transcript = try liveTranscript()
        _ = transcript.apply(frame("tool.start", ["tool_id": "t1", "name": "terminal"], seq: 1))
        #expect(generations(transcript).isEmpty)
    }

    @Test func historyReplayShowsTheSameImageAndFailure() throws {
        let transcript = try history([
            ["role": "tool", "name": "image_generate", "tool_call_id": "t1", "content": .string(Self.success)],
            ["role": "tool", "name": "image_generate", "tool_call_id": "t2", "content": .string("{\"success\": false, \"error\": \"No provider configured\"}")],
        ])
        #expect(generations(transcript) == [
            .ready(ImageReference(source: .hostPath("/Users/me/cache/out.png"))),
            .failed(reason: "No provider configured"),
        ])
    }

    @Test func historyAndLiveAgreeOnTheSameResult() throws {
        let live = ImageGeneration.resolve(status: .finished, prompt: "fox", aspectRatio: nil, result: .string(Self.success))
        let replayed = try history([["role": "tool", "name": "image_generate", "tool_call_id": "t1", "content": .string(Self.success)]])
        #expect(generations(replayed) == [live])
    }
}
