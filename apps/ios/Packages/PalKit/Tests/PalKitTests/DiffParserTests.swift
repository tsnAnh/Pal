import Foundation
import PalChat
import Testing

@Suite("Diff parser")
struct DiffParserTests {
    private func kinds(_ lines: [DiffLine]) -> [DiffLineKind] {
        lines.map(\.kind)
    }

    @Test func emptyInput() {
        #expect(DiffParser.parse("").isEmpty)
        let stats = DiffParser.stats([])
        #expect(stats.added == 0 && stats.removed == 0)
    }

    @Test func gitDiffWithHeadersAndHunk() {
        let source = [
            "diff --git a/f.txt b/f.txt",
            "index 111..222 100644",
            "--- a/f.txt",
            "+++ b/f.txt",
            "@@ -1,3 +1,3 @@",
            " keep",
            "-old",
            "+new",
            "\\ No newline at end of file",
        ].joined(separator: "\n")
        let lines = DiffParser.parse(source)
        #expect(kinds(lines) == [.fileHeader, .meta, .fileHeader, .fileHeader, .hunk, .context, .removed, .added, .meta])
        #expect(lines[4].text == "@@ -1,3 +1,3 @@")
        #expect(lines[5].text == "keep")
        #expect(lines[6].text == "old")
        #expect(lines[7].text == "new")
        #expect(lines[8].text == "\\ No newline at end of file")
        let stats = DiffParser.stats(lines)
        #expect(stats.added == 1 && stats.removed == 1)
    }

    @Test func dashesInsideAHunkAreRemovedLines() {
        let lines = DiffParser.parse("@@ -1,2 +1,1 @@\n--- foo\n+++ bar\n+baz")
        #expect(kinds(lines) == [.hunk, .removed, .added, .added])
        #expect(lines[1].text == "-- foo")
        #expect(lines[2].text == "++ bar")
    }

    @Test func fileHeadersBeforeTheFirstHunkOnly() {
        let lines = DiffParser.parse("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b")
        #expect(kinds(lines) == [.fileHeader, .fileHeader, .hunk, .removed, .added])
    }

    @Test func headerlessSnippetClassifiesByMarker() {
        let lines = DiffParser.parse("+a\n-b\n c\nplain")
        #expect(kinds(lines) == [.added, .removed, .context, .context])
        #expect(lines.map(\.text) == ["a", "b", "c", "plain"])
    }

    @Test func secondFileAfterGitHeaderResetsHeaderZone() {
        let source = "diff --git a/1 b/1\n--- a/1\n+++ b/1\n@@ -1 +1 @@\n-x\n+y\ndiff --git a/2 b/2\nnew file mode 100644\n--- /dev/null\n+++ b/2\n@@ -0,0 +1 @@\n+z"
        let lines = DiffParser.parse(source)
        #expect(kinds(lines) == [
            .fileHeader, .fileHeader, .fileHeader, .hunk, .removed, .added,
            .fileHeader, .meta, .fileHeader, .fileHeader, .hunk, .added,
        ])
    }

    @Test func plainUnifiedSecondFileWithoutGitHeader() {
        let source = "--- a/1\n+++ b/1\n@@ -1 +1 @@\n-x\n+y\n--- a/2\n+++ b/2\n@@ -1 +1 @@\n-p\n+q"
        let lines = DiffParser.parse(source)
        #expect(kinds(lines) == [
            .fileHeader, .fileHeader, .hunk, .removed, .added,
            .fileHeader, .fileHeader, .hunk, .removed, .added,
        ])
    }

    @Test func emptyLinesInsideAHunkAreContext() {
        let lines = DiffParser.parse("@@ -1,3 +1,3 @@\n a\n\n b")
        #expect(kinds(lines) == [.hunk, .context, .context, .context])
        #expect(lines.map(\.text) == ["@@ -1,3 +1,3 @@", "a", "", "b"])
    }

    @Test func contextWithoutLeadingSpaceKeepsItsText() {
        let lines = DiffParser.parse("@@ -1 +1 @@\nnospace")
        #expect(lines[1] == DiffLine(kind: .context, text: "nospace"))
    }

    @Test func crlfLineEndings() {
        let lines = DiffParser.parse("@@ -1 +1 @@\r\n-a\r\n+b\r\n")
        #expect(lines.map(\.text) == ["@@ -1 +1 @@", "a", "b"])
        #expect(kinds(lines) == [.hunk, .removed, .added])
    }

    @Test func arrowHeaderBeforeTheFirstHunk() {
        let lines = DiffParser.parse("a/path.txt → b/path.txt\n@@ -1 +1 @@\n-a\n+b")
        #expect(kinds(lines) == [.fileHeader, .hunk, .removed, .added])
    }

    @Test func similarityRenameAndBinaryAreMeta() {
        let lines = DiffParser.parse("diff --git a/x b/y\nsimilarity index 90%\nrename from x\nrename to y\nBinary files a/p and b/p differ")
        #expect(kinds(lines) == [.fileHeader, .meta, .meta, .meta, .meta])
    }

    @Test func unicodeAndEmojiSurvive() {
        let lines = DiffParser.parse("@@ -1 +1 @@\n-é\n+😀 日本 👨‍👩‍👧")
        #expect(lines[2].text == "😀 日本 👨‍👩‍👧")
    }

    @Test func statsCountOnlyChangedLines() {
        let lines = DiffParser.parse("@@ -1,4 +1,4 @@\n a\n-b\n-c\n+d\n+e\n+f")
        let stats = DiffParser.stats(lines)
        #expect(stats.added == 3)
        #expect(stats.removed == 2)
    }

    @Test func largeDiffParsesAllLines() {
        let body = (0..<50_000).map { $0 % 2 == 0 ? "+line \($0)" : "-line \($0)" }.joined(separator: "\n")
        let lines = DiffParser.parse("@@ -1 +1 @@\n" + body)
        #expect(lines.count == 50_001)
        let stats = DiffParser.stats(lines)
        #expect(stats.added == 25_000 && stats.removed == 25_000)
    }
}
