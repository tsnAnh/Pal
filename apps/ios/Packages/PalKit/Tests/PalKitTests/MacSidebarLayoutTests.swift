import Foundation
import Testing

@Suite("Mac sidebar footer layout")
struct MacSidebarLayoutTests {
    private static let source: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Mac/MacSidebar.swift")

    private func region(from start: String, to end: String) throws -> String {
        let text = try String(contentsOf: Self.source, encoding: .utf8)
        let lower = try #require(text.range(of: start), "\(start) not found")
        let upper = try #require(text.range(of: end, range: lower.upperBound..<text.endIndex), "\(end) not found")
        return String(text[lower.lowerBound..<upper.lowerBound])
    }

    @Test func footerSitsBelowTheListInsteadOfFloatingOverIt() throws {
        let expanded = try region(from: "private var expanded", to: "private var topBar")
        #expect(!expanded.contains("ZStack"), "the footer must not be stacked over the list")
        #expect(!expanded.contains("footerHeight"), "the list inset must come from layout, not a hand-set footer height")
        #expect(!expanded.contains(".mask("), "rows must not fade out under the footer")
        #expect(expanded.contains("MacSidebarFooter("))
    }

    @Test func footerHasItsOwnSidebarBackgroundAndKeepsGlassButtons() throws {
        let footer = try region(from: "private struct MacSidebarFooter", to: "#endif")
        #expect(footer.contains(".background(PalTokens.sidebar)"), "the footer needs an opaque sidebar background")
        #expect(footer.components(separatedBy: ".palGlass(Circle())").count - 1 == 2, "both round buttons stay Liquid Glass")
    }
}
