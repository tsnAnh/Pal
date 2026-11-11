import Foundation
import PalChat
import Testing

@Suite("Rich classifier")
struct RichClassifierTests {
    @Test func languageAliasesMapToTheirKinds() {
        for language in ["diff", "patch", "udiff", "DIFF", " Diff extra"] {
            #expect(RichClassifier.classify(language: language, body: "x") == .diff)
        }
        for language in ["mermaid", "mmd"] {
            #expect(RichClassifier.classify(language: language, body: "graph TD") == .mermaid)
        }
        for language in ["latex", "tex", "math", "katex"] {
            #expect(RichClassifier.classify(language: language, body: "x^2") == .latex)
        }
        for language in ["ansi", "terminal", "console", "term", "output", "log"] {
            #expect(RichClassifier.classify(language: language, body: "$ ls") == .terminal)
        }
    }

    @Test func jsonLanguagesRequireValidJSON() {
        for language in ["json", "jsonc", "json5"] {
            #expect(RichClassifier.classify(language: language, body: "{\"a\": [1, 2]}") == .json)
        }
        #expect(RichClassifier.classify(language: "json", body: "{oops") == .code(language: "json"))
        #expect(RichClassifier.classify(language: "json", body: "42") == .code(language: "json"))
        #expect(RichClassifier.classify(language: "json", body: "") == .code(language: "json"))
        #expect(RichClassifier.classify(language: "jsonc", body: "{\n// c\n\"a\": 1}") == .code(language: "jsonc"))
    }

    @Test func escapeBracketMakesAnyLanguageTerminal() {
        let body = "\u{1B}[1mbold\u{1B}[0m"
        #expect(RichClassifier.classify(language: "swift", body: body) == .terminal)
        #expect(RichClassifier.classify(language: nil, body: body) == .terminal)
        #expect(RichClassifier.classify(language: "diff", body: body) == .terminal)
        #expect(RichClassifier.classify(language: "swift", body: "\u{1B}x") == .code(language: "swift"))
    }

    @Test func diffSniffWithoutLanguage() {
        #expect(RichClassifier.classify(language: nil, body: "diff --git a/x b/x\nindex 1..2") == .diff)
        #expect(RichClassifier.classify(language: nil, body: "--- a/f\n+++ b/f\n") == .diff)
        #expect(RichClassifier.classify(language: nil, body: "@@ -1,2 +1,3 @@\n x") == .diff)
        #expect(RichClassifier.classify(language: nil, body: "@@ -1 +1 @@\n-a\n+b") == .diff)
        #expect(RichClassifier.classify(language: "", body: "--- a\n+++ b") == .diff)
    }

    @Test func nearMissesAreNotDiffs() {
        #expect(RichClassifier.classify(language: nil, body: "--- only\nno plus") == .code(language: nil))
        #expect(RichClassifier.classify(language: nil, body: "@@ bogus") == .code(language: nil))
        #expect(RichClassifier.classify(language: nil, body: "+++ first\n--- second") == .code(language: nil))
    }

    @Test func jsonSniffWithoutLanguage() {
        #expect(RichClassifier.classify(language: nil, body: "{\"a\": [1,2]}") == .json)
        #expect(RichClassifier.classify(language: nil, body: "  [1, 2]\n") == .json)
        #expect(RichClassifier.classify(language: nil, body: "[]") == .json)
        #expect(RichClassifier.classify(language: nil, body: "{}") == .json)
        #expect(RichClassifier.classify(language: nil, body: "[not json") == .code(language: nil))
        #expect(RichClassifier.classify(language: nil, body: "42") == .code(language: nil))
    }

    @Test func plainAndEmptyBodiesFallBackToCode() {
        #expect(RichClassifier.classify(language: nil, body: "hello") == .code(language: nil))
        #expect(RichClassifier.classify(language: nil, body: "") == .code(language: nil))
        #expect(RichClassifier.classify(language: "", body: "") == .code(language: nil))
        #expect(RichClassifier.classify(language: "   ", body: "x") == .code(language: nil))
    }

    @Test func knownLanguagesNeverSniff() {
        #expect(RichClassifier.classify(language: "python", body: "{\"a\":1}") == .code(language: "python"))
        #expect(RichClassifier.classify(language: "swift", body: "--- a\n+++ b") == .code(language: "swift"))
    }

    @Test func unknownLanguagesStillSniffAndKeepTheirName() {
        #expect(RichClassifier.classify(language: "foo", body: "{\"a\":1}") == .json)
        #expect(RichClassifier.classify(language: "FOO", body: "plain") == .code(language: "foo"))
        #expect(RichClassifier.classify(language: "text", body: "diff --git a b") == .diff)
        #expect(RichClassifier.classify(language: "😀 extra", body: "x") == .code(language: "😀"))
    }

    @Test func languageIsLowercasedTrimmedAndFirstWordOnly() {
        #expect(RichClassifier.classify(language: "  Swift  ", body: "let a = 1") == .code(language: "swift"))
        #expect(RichClassifier.classify(language: "JSON title=x", body: "{\"a\":1}") == .json)
    }

    @Test func unicodeJSONIsStillJSON() {
        #expect(RichClassifier.classify(language: nil, body: "{\"k\": \"héllo 😀\"}") == .json)
    }

    @Test func hugeBodiesSkipJSONParsing() {
        let body = "[" + String(repeating: "1,", count: 300_000) + "1]"
        #expect(body.utf8.count > 512 * 1024)
        #expect(RichClassifier.classify(language: nil, body: body) == .code(language: nil))
        #expect(RichClassifier.classify(language: "json", body: body) == .code(language: "json"))
    }

    @Test func crlfDiffIsStillADiff() {
        #expect(RichClassifier.classify(language: nil, body: "--- a\r\n+++ b\r\n@@ -1 +1 @@\r\n") == .diff)
    }
}
