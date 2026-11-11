import Foundation
import HermesChat
import Testing

@Suite("Code highlighter")
struct CodeHighlighterTests {
    private static let languages = [
        "swift", "js", "javascript", "jsx", "ts", "typescript", "tsx", "python", "py", "go", "golang", "rust", "rs",
        "java", "kotlin", "kt", "c", "cpp", "c++", "cc", "h", "hpp", "csharp", "cs", "bash", "sh", "zsh", "shell",
        "json", "jsonc", "yaml", "yml", "toml", "sql", "html", "xml", "svg", "css", "scss", "ruby", "rb", "php",
    ]

    private static let samples = [
        "",
        "plain words only",
        "let x = 42 // trailing\nvar s = \"str \\\" esc\"\n/* block */ func f(a: Int) -> Foo { return Foo(a) }",
        "let s = \"unterminated",
        "/* never closed",
        "\"\"\"\nmulti\nline\n\"\"\"\n'''py'''\n`tick`",
        "{\"a\": [1, 2.5e-3, true, null], \"b\": {\"c\": \"d\"}}",
        "name: value\nlist:\n  - a-b\n  - 'q'\nurl: http://x.example\n# c",
        "<!DOCTYPE html><html><body class=\"a\" id='b'><!-- c --><p>1 < 2 &amp; 3</p><br/></body></html>",
        "<unterminated attr=\"x",
        "<",
        "a { color: #fff; margin: -10px auto; content: \"x\" } @media (min-width: 1px) {}",
        "SELECT a, COUNT(*) FROM t WHERE x = 'it''s' -- c\nORDER BY 1;",
        "#!/bin/bash\necho \"$HOME ${PATH} $1 $#\" # c\nif [ -f x ]; then ls; fi",
        "<?php $a = 'x'; echo \"$a\"; // c\n# d\n",
        "@Override\npublic static void main(String[] args) { int x = 0x1F + 1_000; }",
        "#include <stdio.h>\nint main(void) { return 0; }",
        "def f(x):\n    return x @ y  # c\n@decorator\nclass Foo: pass",
        "café 😀 👨‍👩‍👧 é = \"日本語\" // ü",
        "line1\r\nline2\r\n\"crlf\"\r\n",
        "\u{1B}[31mred\u{1B}[0m \t\u{0}\u{7F}",
        "1.2.3 .5 1..2 0x 1e+ 1e+5 9e",
        "\\ \\\" \"\\",
    ]

    private func joined(_ spans: [CodeSpan]) -> String {
        spans.map(\.text).joined()
    }

    private func assertNoAdjacentDuplicates(_ spans: [CodeSpan]) -> Bool {
        zip(spans, spans.dropFirst()).allSatisfy { $0.kind != $1.kind } && spans.allSatisfy { !$0.text.isEmpty }
    }

    @Test func everyLanguageAliasIsKnown() {
        for language in Self.languages {
            #expect(CodeHighlighter.spans(language: language, code: "x") != nil, "\(language)")
        }
    }

    @Test func resultIsLosslessForEveryLanguageAndSample() {
        for language in Self.languages {
            for sample in Self.samples {
                guard let spans = CodeHighlighter.spans(language: language, code: sample) else {
                    Issue.record("nil for \(language)")
                    continue
                }
                #expect(joined(spans) == sample, "\(language) lost text for \(sample.debugDescription)")
                #expect(assertNoAdjacentDuplicates(spans), "\(language) did not merge \(sample.debugDescription)")
            }
        }
    }

    @Test func unknownOrMissingLanguageIsNil() {
        #expect(CodeHighlighter.spans(language: nil, code: "x") == nil)
        #expect(CodeHighlighter.spans(language: "", code: "x") == nil)
        #expect(CodeHighlighter.spans(language: "brainfuck", code: "+++") == nil)
        #expect(CodeHighlighter.spans(language: "mermaid", code: "graph") == nil)
    }

    @Test func languageIsNormalised() {
        #expect(CodeHighlighter.spans(language: " Swift extra", code: "let a = 1") != nil)
        #expect(CodeHighlighter.spans(language: "C++", code: "int a;") != nil)
    }

    @Test func oversizedCodeIsNil() {
        let limit = CodeHighlighter.characterLimit
        #expect(CodeHighlighter.spans(language: "swift", code: String(repeating: "a", count: limit + 1)) == nil)
        let atLimit = String(repeating: "a", count: limit)
        #expect(CodeHighlighter.spans(language: "swift", code: atLimit).map(joined) == atLimit)
    }

    @Test func emptyCodeIsAnEmptyResultNotNil() {
        #expect(CodeHighlighter.spans(language: "swift", code: "") == [])
    }

    @Test func largeInputStaysLossless() {
        let code = String(repeating: "let x = foo(1, \"s\") // c\n", count: 1_400)
        let spans = CodeHighlighter.spans(language: "swift", code: code)
        #expect(spans.map(joined) == code)
    }

    @Test func swiftTokens() {
        let spans = CodeHighlighter.spans(language: "swift", code: "let x = 42 // hi") ?? []
        #expect(spans.contains(CodeSpan(text: "let", kind: .keyword)))
        #expect(spans.contains(CodeSpan(text: "42", kind: .number)))
        #expect(spans.contains(CodeSpan(text: "// hi", kind: .comment)))
        #expect(spans.contains(CodeSpan(text: "=", kind: .punctuation)))
    }

    @Test func stringsKeepEscapedQuotes() {
        let code = "let s = \"hi \\\"there\\\"\""
        let spans = CodeHighlighter.spans(language: "swift", code: code) ?? []
        #expect(spans.contains(CodeSpan(text: "\"hi \\\"there\\\"\"", kind: .string)))
    }

    @Test func typesFunctionsAndAttributes() {
        let spans = CodeHighlighter.spans(language: "swift", code: "@MainActor\nlet v = Foo(bar(1))") ?? []
        #expect(spans.contains(CodeSpan(text: "@MainActor", kind: .attribute)))
        #expect(spans.contains(CodeSpan(text: "Foo", kind: .type)))
        #expect(spans.contains(CodeSpan(text: "bar", kind: .function)))
    }

    @Test func unterminatedBlockCommentRunsToTheEnd() {
        let spans = CodeHighlighter.spans(language: "go", code: "x /* open\nstill") ?? []
        #expect(spans.last == CodeSpan(text: "/* open\nstill", kind: .comment))
    }

    @Test func pythonTripleQuotesSpanLines() {
        let spans = CodeHighlighter.spans(language: "py", code: "s = \"\"\"a\nb\"\"\"") ?? []
        #expect(spans.contains(CodeSpan(text: "\"\"\"a\nb\"\"\"", kind: .string)))
    }

    @Test func jsonKeysAreAttributesAndValuesAreNot() {
        let spans = CodeHighlighter.spans(language: "json", code: "{\"a\": 1, \"b\": \"x\", \"c\": true}") ?? []
        #expect(spans.contains(CodeSpan(text: "\"a\"", kind: .attribute)))
        #expect(spans.contains(CodeSpan(text: "\"b\"", kind: .attribute)))
        #expect(spans.contains(CodeSpan(text: "\"x\"", kind: .string)))
        #expect(spans.contains(CodeSpan(text: "1", kind: .number)))
        #expect(spans.contains(CodeSpan(text: "true", kind: .keyword)))
    }

    @Test func yamlKeysNeedAColonThenSpace() {
        let spans = CodeHighlighter.spans(language: "yaml", code: "name: pat\nurl: http://x.example") ?? []
        let attributes = spans.filter { $0.kind == .attribute }.map(\.text)
        #expect(attributes == ["name", "url"])
    }

    @Test func htmlTagsAttributesAndComments() {
        let spans = CodeHighlighter.spans(language: "html", code: "<a href=\"x\">hi</a><!-- c -->") ?? []
        #expect(spans.contains(CodeSpan(text: "a", kind: .keyword)))
        #expect(spans.contains(CodeSpan(text: "href", kind: .attribute)))
        #expect(spans.contains(CodeSpan(text: "\"x\"", kind: .string)))
        #expect(spans.contains(CodeSpan(text: "<!-- c -->", kind: .comment)))
    }

    @Test func sqlKeywordsIgnoreCase() {
        let spans = CodeHighlighter.spans(language: "sql", code: "select 1 FROM t") ?? []
        #expect(spans.contains(CodeSpan(text: "select", kind: .keyword)))
        #expect(spans.contains(CodeSpan(text: "FROM", kind: .keyword)))
    }

    @Test func shellCommentsAndVariables() {
        let spans = CodeHighlighter.spans(language: "bash", code: "# c\necho $HOME") ?? []
        #expect(spans.contains(CodeSpan(text: "# c", kind: .comment)))
        #expect(spans.contains(CodeSpan(text: "$HOME", kind: .attribute)))
    }

    @Test func cssColorsAndUnits() {
        let spans = CodeHighlighter.spans(language: "css", code: "a { color: #fff; margin: 10px }") ?? []
        #expect(spans.contains(CodeSpan(text: "#fff", kind: .number)))
        #expect(spans.contains(CodeSpan(text: "10px", kind: .number)))
    }
}
