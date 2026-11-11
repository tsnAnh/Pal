import Foundation
import PalChat
import Testing

@Suite("Speech chunker")
struct SpeechChunkerTests {
    @Test func emitsNothingUntilASentenceCompletes() {
        var chunker = SpeechChunker()
        #expect(chunker.consume("Xin chào anh", isFinal: false).isEmpty)
        #expect(chunker.consume("Xin chào anh. Em", isFinal: false) == ["Xin chào anh."])
    }

    @Test func sameTextTwiceEmitsOnce() {
        var chunker = SpeechChunker()
        #expect(chunker.consume("Một. Hai.", isFinal: false) == ["Một."])
        #expect(chunker.consume("Một. Hai.", isFinal: false).isEmpty)
    }

    @Test func finalFlushEmitsTheTail() {
        var chunker = SpeechChunker()
        _ = chunker.consume("Một. Hai", isFinal: false)
        #expect(chunker.consume("Một. Hai ba", isFinal: true) == ["Hai ba"])
        #expect(chunker.consume("Một. Hai ba", isFinal: true).isEmpty)
    }

    @Test func decimalsAndDomainsDoNotSplit() {
        var chunker = SpeechChunker()
        #expect(chunker.consume("Giá 6.5 triệu trên example.com nhé. Xong", isFinal: false) == ["Giá 6.5 triệu trên example.com nhé."])
    }

    @Test func questionExclamationEllipsisAndNewlineAreBoundaries() {
        var chunker = SpeechChunker()
        let out = chunker.consume("Thật không? Tuyệt! Ừm… ok\ncòn nữa", isFinal: false)
        #expect(out == ["Thật không?", "Tuyệt!", "Ừm…", "ok"])
    }

    @Test func markdownIsStrippedForSpeech() {
        var chunker = SpeechChunker()
        let out = chunker.consume("**Lưu ý:** xem [Google Payments](https://pay.google.com) nhé.\n- một\n- hai\n", isFinal: true)
        #expect(out.joined(separator: " ") == "Lưu ý: xem Google Payments nhé. một hai")
    }

    @Test func codeBlocksAreNotRead() {
        var chunker = SpeechChunker()
        let out = chunker.consume("Chạy lệnh này.\n\n```sh\nrm -rf /\n```\n\nXong.", isFinal: true)
        #expect(out.joined(separator: " ") == "Chạy lệnh này. Xong.")
    }

    @Test func aLongRunWithoutPunctuationIsSplitOnASpace() {
        var chunker = SpeechChunker(maximumLength: 40)
        let text = "một hai ba bốn năm sáu bảy tám chín mười mười một mười hai mười ba"
        let out = chunker.consume(text, isFinal: true)
        #expect(out.count > 1)
        #expect(out.allSatisfy { $0.count <= 40 })
        #expect(out.joined(separator: " ") == text)
    }

    @Test func replacedFinalTextOnlySpeaksWhatIsNew() {
        var chunker = SpeechChunker()
        #expect(chunker.consume("Một. Hai.", isFinal: false) == ["Một."])
        #expect(chunker.consume("Một. Hai. Ba.", isFinal: true) == ["Hai.", "Ba."])
    }

    @Test func resetStartsOver() {
        var chunker = SpeechChunker()
        _ = chunker.consume("Một. Hai.", isFinal: true)
        chunker.reset()
        #expect(chunker.consume("Ba.", isFinal: true) == ["Ba."])
    }

    @Test func emptyAndWhitespaceTextSpeakNothing() {
        var chunker = SpeechChunker()
        #expect(chunker.consume("", isFinal: true).isEmpty)
        #expect(chunker.consume("  \n ", isFinal: true).isEmpty)
    }
}
