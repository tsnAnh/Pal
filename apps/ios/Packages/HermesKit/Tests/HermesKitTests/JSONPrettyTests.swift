import Foundation
import HermesChat
import Testing

@Suite("JSON pretty")
struct JSONPrettyTests {
    @Test func reindentsAndKeepsKeyOrder() throws {
        let presentation = try #require(JSONPretty.present("{\"b\":1,\"a\":[1,2],\"c\":{}}"))
        let expected = """
        {
          "b": 1,
          "a": [
            1,
            2
          ],
          "c": {}
        }
        """
        #expect(presentation.pretty == expected)
        #expect(presentation.summary == "{ 3 keys }")
    }

    @Test func summaries() {
        #expect(JSONPretty.present("[1,2,3]")?.summary == "[ 3 items ]")
        #expect(JSONPretty.present("[1]")?.summary == "[ 1 item ]")
        #expect(JSONPretty.present("{\"a\":1}")?.summary == "{ 1 key }")
        #expect(JSONPretty.present("[]")?.summary == "[ 0 items ]")
        #expect(JSONPretty.present("{}")?.summary == "{ 0 keys }")
    }

    @Test func emptyContainersStayInline() {
        #expect(JSONPretty.present("[]")?.pretty == "[]")
        #expect(JSONPretty.present(" {  \n } ")?.pretty == "{}")
        #expect(JSONPretty.present("[[],{}]")?.pretty == "[\n  [],\n  {}\n]")
    }

    @Test func stringsAreNeverReindented() throws {
        let source = "{\"k\":\"a,b:{c}[d] \\\"e\\\" \\\\\"}"
        let presentation = try #require(JSONPretty.present(source))
        #expect(presentation.pretty == "{\n  \"k\": \"a,b:{c}[d] \\\"e\\\" \\\\\"\n}")
    }

    @Test func originalNumberTokensAreKept() {
        #expect(JSONPretty.present("{\"n\":1.0e10,\"m\":-0.50}")?.pretty == "{\n  \"n\": 1.0e10,\n  \"m\": -0.50\n}")
    }

    @Test func existingWhitespaceIsNormalised() {
        #expect(JSONPretty.present("{\n\t\"a\" :\t1\n}")?.pretty == "{\n  \"a\": 1\n}")
    }

    @Test func invalidInputIsNil() {
        for source in ["", "   ", "{oops", "[1,]", "{\"a\":}", "not json", "{'a':1}", "[1] extra"] {
            #expect(JSONPretty.present(source) == nil, "\(source.debugDescription)")
        }
    }

    @Test func fragments() throws {
        let number = try #require(JSONPretty.present("42"))
        #expect(number.pretty == "42")
        #expect(number.summary == "value")
        #expect(JSONPretty.present("\"s\"")?.summary == "string")
    }

    @Test func unicodeSurvives() throws {
        let presentation = try #require(JSONPretty.present("{\"k\":\"héllo 😀 日本\"}"))
        #expect(presentation.pretty == "{\n  \"k\": \"héllo 😀 日本\"\n}")
    }

    @Test func oversizedInputIsNil() {
        let source = "[" + String(repeating: "1,", count: 600_000) + "1]"
        #expect(source.utf8.count > 1_000_000)
        #expect(JSONPretty.present(source) == nil)
    }

    @Test func largeValidInputIsHandled() throws {
        let source = "[" + (0..<20_000).map(String.init).joined(separator: ",") + "]"
        let presentation = try #require(JSONPretty.present(source))
        #expect(presentation.summary == "[ 20000 items ]")
        #expect(presentation.pretty.split(separator: "\n").count == 20_002)
    }

    @Test func reformattingIsIdempotent() throws {
        let first = try #require(JSONPretty.present("{\"a\":[{\"b\":null},true],\"c\":\"x\"}"))
        let second = try #require(JSONPretty.present(first.pretty))
        #expect(second.pretty == first.pretty)
    }
}
