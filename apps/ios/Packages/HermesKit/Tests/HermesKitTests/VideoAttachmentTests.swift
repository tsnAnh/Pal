import Foundation
import HermesChat
import Testing

@Suite("Video attachments")
struct VideoAttachmentTests {
    @Test func remoteVideoTokenBecomesStandaloneLine() {
        let content = MessageImages.extract(from: "Here it is\nMEDIA:https://cdn.example.com/clip.mp4", role: .assistant)
        #expect(content.text == "Here it is\n\nhttps://cdn.example.com/clip.mp4")
        #expect(content.images.isEmpty)
    }

    @Test func videoOnlyMessageKeepsJustTheLink() {
        let content = MessageImages.extract(from: "MEDIA:https://cdn.example.com/clip.m3u8", role: .assistant)
        #expect(content.text == "https://cdn.example.com/clip.m3u8")
    }

    @Test func hostFilePathVideoIsLeftAlone() {
        let text = "Done\nMEDIA:/home/agent/out/clip.mp4"
        #expect(MessageImages.extract(from: text, role: .assistant).text == text)
    }

    @Test func nonPlayableRemoteExtensionIsLeftAlone() {
        let text = "MEDIA:https://cdn.example.com/clip.webm"
        #expect(MessageImages.extract(from: text, role: .assistant).text == text)
    }

    @Test func videoAndImageTogether() {
        let content = MessageImages.extract(
            from: "MEDIA:https://cdn.example.com/a.png MEDIA:https://cdn.example.com/b.mov",
            role: .assistant
        )
        #expect(content.images.count == 1)
        #expect(content.text == "https://cdn.example.com/b.mov")
    }
}
