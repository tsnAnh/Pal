import Foundation
import HermesChat
import Testing

@Suite("ANSI parser")
struct ANSIParserTests {
    private let esc = "\u{1B}"

    @Test func detectsEscapes() {
        #expect(ANSIParser.containsEscapes("a\u{1B}[0m"))
        #expect(!ANSIParser.containsEscapes("plain"))
        #expect(!ANSIParser.containsEscapes(""))
    }

    @Test func emptyAndPlainInput() {
        #expect(ANSIParser.parse("").isEmpty)
        #expect(ANSIParser.parse("plain") == [ANSISegment(text: "plain")])
    }

    @Test func basicColorsAndReset() {
        let segments = ANSIParser.parse("\(esc)[31mred\(esc)[0m ok")
        #expect(segments == [ANSISegment(text: "red", foreground: .standard(1)), ANSISegment(text: " ok")])
    }

    @Test func boldWithColor() {
        #expect(ANSIParser.parse("\(esc)[1;32mgo") == [ANSISegment(text: "go", foreground: .standard(2), bold: true)])
    }

    @Test func brightAndBackgroundColors() {
        #expect(ANSIParser.parse("\(esc)[91mx") == [ANSISegment(text: "x", foreground: .bright(1))])
        #expect(ANSIParser.parse("\(esc)[44mx") == [ANSISegment(text: "x", background: .standard(4))])
        #expect(ANSIParser.parse("\(esc)[104mx") == [ANSISegment(text: "x", background: .bright(4))])
    }

    @Test func extendedColorsAreClamped() {
        #expect(ANSIParser.parse("\(esc)[38;5;208mx") == [ANSISegment(text: "x", foreground: .indexed(208))])
        #expect(ANSIParser.parse("\(esc)[38;5;300mx") == [ANSISegment(text: "x", foreground: .indexed(255))])
        #expect(ANSIParser.parse("\(esc)[38;2;1;2;3mx") == [ANSISegment(text: "x", foreground: .rgb(1, 2, 3))])
        #expect(ANSIParser.parse("\(esc)[48;2;999;0;7mx") == [ANSISegment(text: "x", background: .rgb(255, 0, 7))])
    }

    @Test func colonSeparatedExtendedColors() {
        #expect(ANSIParser.parse("\(esc)[38:5:12mx") == [ANSISegment(text: "x", foreground: .indexed(12))])
        #expect(ANSIParser.parse("\(esc)[38:2::10:20:30mx") == [ANSISegment(text: "x", foreground: .rgb(10, 20, 30))])
    }

    @Test func truncatedExtendedColorDoesNotCrashOrSwallowText() {
        #expect(ANSIParser.stripped("\(esc)[38;5mx") == "x")
        #expect(ANSIParser.stripped("\(esc)[38;2;1;2mx") == "x")
        #expect(ANSIParser.stripped("\(esc)[38mx") == "x")
    }

    @Test func emptyParametersMeanReset() {
        #expect(ANSIParser.parse("\(esc)[1m\(esc)[mx") == [ANSISegment(text: "x")])
        #expect(ANSIParser.parse("\(esc)[1;mx") == [ANSISegment(text: "x")])
    }

    @Test func dimItalicUnderlineAndTheirOffCodes() {
        let segments = ANSIParser.parse("\(esc)[2;3;4mx\(esc)[22;23;24my")
        #expect(segments == [ANSISegment(text: "x", dim: true, italic: true, underline: true), ANSISegment(text: "y")])
    }

    @Test func defaultColorCodesClearOnlyTheirOwnSide() {
        let segments = ANSIParser.parse("\(esc)[31;42mx\(esc)[39my\(esc)[49mz")
        #expect(segments == [
            ANSISegment(text: "x", foreground: .standard(1), background: .standard(2)),
            ANSISegment(text: "y", background: .standard(2)),
            ANSISegment(text: "z"),
        ])
    }

    @Test func reverseVideoIsIgnored() {
        #expect(ANSIParser.parse("\(esc)[7mx") == [ANSISegment(text: "x")])
    }

    @Test func otherCSISequencesAreDropped() {
        #expect(ANSIParser.stripped("a\(esc)[2Kb\(esc)[1;1Hc\(esc)[?25ld\(esc)[?1049h") == "abcd")
        #expect(ANSIParser.parse("a\(esc)[2Kb") == [ANSISegment(text: "ab")])
    }

    @Test func privateSGRLookalikeIsNotApplied() {
        #expect(ANSIParser.parse("\(esc)[?31mx") == [ANSISegment(text: "x")])
    }

    @Test func oscSequencesAreDropped() {
        #expect(ANSIParser.stripped("a\(esc)]0;title\u{07}b") == "ab")
        #expect(ANSIParser.stripped("a\(esc)]8;;http://x.example\(esc)\\b") == "ab")
    }

    @Test func unterminatedOSCDropsTheRest() {
        #expect(ANSIParser.stripped("a\(esc)]0;title") == "a")
    }

    @Test func loneAndTruncatedEscapesNeverLeak() {
        for input in ["\(esc)", "a\(esc)", "a\(esc)[", "a\(esc)[3", "a\(esc)[31", "a\(esc)[31;", "a\(esc)]", "a\(esc)[38;5;", "\(esc)\(esc)\(esc)"] {
            let output = ANSIParser.stripped(input)
            #expect(!output.contains(esc), "leaked in \(input.debugDescription)")
            #expect(output == "a" || output.isEmpty, "unexpected \(output.debugDescription)")
        }
    }

    @Test func escapeBeforeNewlineKeepsTheNewline() {
        #expect(ANSIParser.stripped("a\(esc)\nb") == "a\nb")
    }

    @Test func twoCharacterEscapesAreDropped() {
        #expect(ANSIParser.stripped("a\(esc)Mb\(esc)7c\(esc)(Bd") == "abcd")
    }

    @Test func malformedCSIKeepsFollowingText() {
        let output = ANSIParser.stripped("a\(esc)[3\u{01}b")
        #expect(!output.contains(esc))
        #expect(output.hasPrefix("a"))
        #expect(output.hasSuffix("b"))
    }

    @Test func carriageReturnKeepsOnlyTheLastWrite() {
        #expect(ANSIParser.stripped("50%\r100%") == "100%")
        #expect(ANSIParser.stripped("line1\nfoo\rbar") == "line1\nbar")
        #expect(ANSIParser.stripped("done\r") == "done")
        #expect(ANSIParser.stripped("a\rb\rc") == "c")
    }

    @Test func crlfBecomesLf() {
        #expect(ANSIParser.stripped("abc\r\ndef\r\n") == "abc\ndef\n")
    }

    @Test func styleSurvivesNewlinesAndEqualNeighboursMerge() {
        #expect(ANSIParser.parse("\(esc)[31ma\nb\(esc)[0m") == [ANSISegment(text: "a\nb", foreground: .standard(1))])
        #expect(ANSIParser.parse("\(esc)[31ma\(esc)[31mb") == [ANSISegment(text: "ab", foreground: .standard(1))])
    }

    @Test func controlBytesAreDropped() {
        #expect(ANSIParser.stripped("a\u{07}b\u{0}c") == "abc")
    }

    @Test func unicodeSurvives() {
        let segments = ANSIParser.parse("\(esc)[32mé😀 日本\(esc)[0m 👨‍👩‍👧")
        #expect(segments == [ANSISegment(text: "é😀 日本", foreground: .standard(2)), ANSISegment(text: " 👨‍👩‍👧")])
    }

    @Test func hugeInputIsLinear() {
        let chunk = "\u{1B}[31mx\u{1B}[0m"
        let input = String(repeating: chunk, count: 20_000)
        #expect(ANSIParser.stripped(input).count == 20_000)
        let wide = String(repeating: "a", count: 500_000)
        #expect(ANSIParser.stripped(wide).count == 500_000)
    }
}
