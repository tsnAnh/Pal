@testable import PalDesign
import Testing

@Suite("Bot settings close and back")
struct BotSettingsNavigationTests {
    @Test func aFirstLevelScreenShowsOnlyCloseAndEscapeCloses() {
        let first = BotSettingsNavigation(depth: 0)
        #expect(!first.showsBack)
        #expect(first.exit(for: .escape) == .close)
        #expect(first.exit(for: .closeButton) == .close)
        #expect(first.escapeExit == .close)
    }

    @Test func aNestedStepShowsBackAndEscapePopsOneLevel() {
        for depth in 1...2 {
            let nested = BotSettingsNavigation(depth: depth)
            #expect(nested.showsBack)
            #expect(nested.exit(for: .escape) == .back)
            #expect(nested.exit(for: .backButton) == .back)
            #expect(nested.escapeExit == .back)
        }
    }

    @Test func theCloseButtonLeavesTheWholeFlowFromAnyDepth() {
        for depth in 0...2 {
            #expect(BotSettingsNavigation(depth: depth).exit(for: .closeButton) == .close)
        }
    }

    @Test func aNegativeDepthIsTheFirstLevel() {
        #expect(BotSettingsNavigation(depth: -1) == BotSettingsNavigation(depth: 0))
    }
}
