import Foundation
import PalChat
import Testing

@Suite("Assistant file directives")
struct MessageFilesTests {
    private let csv = "/home/tsnanh/smilewallpaper-research/app-audit.csv"
    private let markdown = "/home/tsnanh/smilewallpaper-research/feature-flows-v0.1.md"

    @Test("two consecutive directives become two cards with the gateway's asset refs")
    func twoConsecutiveDirectives() {
        let content = MessageImages.extract(from: "MEDIA:\(csv)\nMEDIA:\(markdown)", role: .assistant)
        #expect(content.text.isEmpty)
        #expect(content.files.map(\.name) == ["app-audit.csv", "feature-flows-v0.1.md"])
        #expect(content.files.map(\.typeLabel) == ["CSV", "MD"])
        #expect(content.files.map(\.id) == ["ef6dab1fc086c186833781fbc205fe76", "39b685030d5b3d6681f60eb48f25528e"])
        #expect(content.images.isEmpty)
    }

    @Test("surrounding prose is kept and only the directive is removed")
    func proseSurvives() {
        let content = MessageImages.extract(from: "Here you go.\nMEDIA:\(csv)\nMEDIA:\(markdown)\nTell me what to change.", role: .assistant)
        #expect(content.text == "Here you go.\nTell me what to change.")
        #expect(content.files.count == 2)
    }

    @Test("a directive inside a code fence or inline code is literal text")
    func codeIsLiteral() {
        let fenced = "Example:\n```\nMEDIA:\(csv)\n```"
        let inline = "Write `MEDIA:\(csv)` to attach a file."
        for text in [fenced, inline] {
            let content = MessageImages.extract(from: text, role: .assistant)
            #expect(content.text == text)
            #expect(content.images.isEmpty)
            #expect(content.files.isEmpty)
        }
    }

    @Test("malformed directives stay as text")
    func malformedStaysText() {
        for text in ["MEDIA:", "MEDIA:relative/report.csv", "MEDIA:file:///etc/passwd", "MEDIA:/", "MEDIA:/dir/", "MEDIA:~/report.csv"] {
            let content = MessageImages.extract(from: text, role: .assistant)
            #expect(content.text == text)
            #expect(content.files.isEmpty)
        }
    }

    @Test("images and videos keep their own handling")
    func imagesAndVideosUnchanged() {
        let content = MessageImages.extract(from: "MEDIA:/h/cache/images/chart.png\nMEDIA:/home/agent/out/clip.mp4\nMEDIA:\(csv)", role: .assistant)
        #expect(content.images.map(\.name) == ["chart.png"])
        #expect(content.text == "MEDIA:/home/agent/out/clip.mp4")
        #expect(content.files.map(\.name) == ["app-audit.csv"])
    }

    @Test("a path cut off by streaming is not turned into a card")
    func streamingTailWaits() {
        let partial = "Done\nMEDIA:/home/tsnanh/app-aud"
        #expect(MessageImages.extract(from: partial, role: .assistant, isStreaming: true).files.isEmpty)
        #expect(MessageImages.extract(from: partial + "it.csv\n", role: .assistant, isStreaming: true).files.map(\.name) == ["app-audit.csv"])
        #expect(MessageImages.extract(from: partial + "it.csv", role: .assistant).files.map(\.name) == ["app-audit.csv"])
    }

    @Test("duplicates collapse and user messages are never read")
    func duplicatesAndUserRole() {
        #expect(MessageImages.extract(from: "MEDIA:\(csv) MEDIA:\(csv)", role: .assistant).files.count == 1)
        #expect(MessageImages.extract(from: "MEDIA:\(csv)", role: .user).files.isEmpty)
    }

    @Test("audio files share the gateway's media id kind")
    func audioKind() {
        let file = FileReference(path: "/h/out/note.mp3", directive: "MEDIA:/h/out/note.mp3")
        #expect(file.id == ImageReference.assetRef(forHostPath: "/h/out/note.mp3"))
    }
}
