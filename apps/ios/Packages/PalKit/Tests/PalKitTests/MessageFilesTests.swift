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

    @Test("images keep their own renderer, local videos become file cards")
    func imagesStayVideosBecomeCards() {
        let content = MessageImages.extract(from: "MEDIA:/h/cache/images/chart.png\nMEDIA:/home/agent/out/clip.mp4\nMEDIA:\(csv)", role: .assistant)
        #expect(content.images.map(\.name) == ["chart.png"])
        #expect(content.text.isEmpty)
        #expect(content.files.map(\.name) == ["clip.mp4", "app-audit.csv"])
    }

    @Test("every local video extension is a file card with its type label")
    func localVideosAreCards() {
        for ext in ["mp4", "mov", "webm", "mkv", "m4v", "avi", "MP4"] {
            let path = "/home/agent/out/clip.\(ext)"
            let content = MessageImages.extract(from: "Rendered.\nMEDIA:\(path)", role: .assistant)
            #expect(content.text == "Rendered.")
            #expect(content.images.isEmpty)
            #expect(content.files.map(\.name) == ["clip.\(ext)"])
            #expect(content.files.map(\.typeLabel) == [ext.uppercased()])
        }
    }

    @Test("a preview directive for a local video is a file card too")
    func previewVideoCard() {
        let content = MessageImages.extract(from: "::preview{file=\"/home/agent/out/clip.mp4\"}", role: .assistant)
        #expect(content.files.map(\.name) == ["clip.mp4"])
    }

    @Test("https video links are not host paths and stay with the inline player")
    func remoteVideosAreNotCards() {
        for url in ["https://cdn.example.com/clip.mp4", "https://cdn.example.com/live/index.m3u8"] {
            let content = MessageImages.extract(from: "MEDIA:\(url)", role: .assistant)
            #expect(content.files.isEmpty)
            #expect(content.text == url)
        }
        #expect(MessageFiles.extract(from: "MEDIA:https://cdn.example.com/clip.mp4", isStreaming: false).files.isEmpty)
    }

    @Test("a video path still being streamed waits, and a repeated video makes one card")
    func videoStreamingAndDuplicates() {
        let partial = "Done\nMEDIA:/home/agent/out/cl"
        #expect(MessageImages.extract(from: partial, role: .assistant, isStreaming: true).files.isEmpty)
        #expect(MessageImages.extract(from: partial + "ip.mp4", role: .assistant).files.map(\.name) == ["clip.mp4"])
        #expect(MessageImages.extract(from: "MEDIA:/h/clip.mov MEDIA:/h/clip.mov", role: .assistant).files.count == 1)
    }

    @Test("an mp3 stays a file card")
    func mp3StaysCard() {
        #expect(MessageImages.extract(from: "MEDIA:/h/out/note.mp3", role: .assistant).files.map(\.typeLabel) == ["MP3"])
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

    @Test("audio and video files share the gateway's media id kind")
    func mediaKind() {
        for path in ["/h/out/note.mp3", "/h/out/clip.mp4", "/h/out/clip.MOV"] {
            #expect(FileReference(path: path, directive: "MEDIA:\(path)").id == ImageReference.assetRef(forHostPath: path))
        }
        #expect(FileReference(path: "/h/out/a.csv", directive: "").id != ImageReference.assetRef(forHostPath: "/h/out/a.csv"))
    }

    private let page = "/home/tsnanh/chief-checks/mockup-connect-apps-iphone-colours.html"

    @Test("a MEDIA path to an HTML mockup is a file card with the gateway's ref")
    func mediaHTMLPath() {
        let content = MessageImages.extract(from: "Here it is.\nMEDIA:\(page)", role: .assistant)
        #expect(content.text == "Here it is.")
        #expect(content.files.map(\.name) == ["mockup-connect-apps-iphone-colours.html"])
        #expect(content.files.map(\.typeLabel) == ["HTML"])
        #expect(content.files.first?.id == MessageFiles.assetRef(forHostPath: page))
    }

    @Test("a preview directive alone on a line becomes the same card as a MEDIA tag and leaves the text")
    func previewDirectiveBecomesCard() {
        let preview = MessageImages.extract(from: "Look:\n::preview{file=\"\(page)\"}\nDone.", role: .assistant)
        let media = MessageImages.extract(from: "Look:\nMEDIA:\(page)\nDone.", role: .assistant)
        #expect(preview.text == "Look:\nDone.")
        #expect(preview.files == media.files.map { FileReference(path: $0.path, directive: "::preview{file=\"\(page)\"}") })
        #expect(preview.files.map(\.id) == media.files.map(\.id))
    }

    @Test("single quotes and extra attributes are read, a preview and a MEDIA tag for one path make one card")
    func previewQuotesAndDuplicates() {
        let single = MessageImages.extract(from: "::preview{file='\(page)'}", role: .assistant)
        #expect(single.files.map(\.name) == ["mockup-connect-apps-iphone-colours.html"])
        let extra = MessageImages.extract(from: "  ::preview{title=\"Colours\" file=\"\(page)\"}  ", role: .assistant)
        #expect(extra.files.count == 1)
        #expect(extra.text.isEmpty)
        let both = MessageImages.extract(from: "::preview{file=\"\(page)\"}\nMEDIA:\(page)", role: .assistant)
        #expect(both.files.count == 1)
    }

    @Test("unknown directives, fenced directives and directives that share a line stay text")
    func previewLookalikesStayText() {
        let cases = [
            "::chart{file=\"\(page)\"}",
            "Example:\n```\n::preview{file=\"\(page)\"}\n```",
            "see ::preview{file=\"\(page)\"} here",
            "::preview{file=\"relative/page.html\"}",
            "::preview{url=\"\(page)\"}",
            "::preview{file=\"\(page)\"",
        ]
        for text in cases {
            let content = MessageImages.extract(from: text, role: .assistant)
            #expect(content.text == text)
            #expect(content.files.isEmpty)
        }
    }

    @Test("a preview line still being streamed waits for its closing brace")
    func previewStreamingTailWaits() {
        let partial = "Done\n::preview{file=\"/home/tsnanh/chief-checks/mock"
        #expect(MessageImages.extract(from: partial, role: .assistant, isStreaming: true).files.isEmpty)
        #expect(MessageImages.extract(from: "Done\n::preview{file=\"\(page)\"}", role: .assistant, isStreaming: true).files.count == 1)
    }
}
