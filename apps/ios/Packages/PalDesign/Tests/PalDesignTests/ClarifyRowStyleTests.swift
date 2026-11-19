import Testing
@testable import PalDesign

@Suite("Clarify row style")
struct ClarifyRowStyleTests {
    private static let palettes = [PalPalette.measuredDark, .derivedLight]

    @Test func unchosenRowsAreSecondaryAndChosenRowsPrimary() {
        for palette in Self.palettes {
            #expect(ClarifyRowStyle.choice.text(in: palette) == palette.textSecondary)
            #expect(ClarifyRowStyle.chosen.text(in: palette) == palette.textPrimary)
            #expect(ClarifyRowStyle.choice.text(in: palette) != ClarifyRowStyle.chosen.text(in: palette))
        }
    }

    @Test func inlineInputUsesTheSameTokensAsOptions() {
        for palette in Self.palettes {
            for style in [ClarifyRowStyle.choice, .chosen] {
                #expect(style.placeholder(in: palette) == ClarifyRowStyle.choice.text(in: palette))
                #expect(style.typedText(in: palette) == ClarifyRowStyle.chosen.text(in: palette))
            }
        }
    }

    @Test func chosenBadgeUsesTheSelectedChipTokens() {
        for palette in Self.palettes {
            #expect(ClarifyRowStyle.chosen.badgeFill(in: palette) == palette.chipSelectedFill)
            #expect(ClarifyRowStyle.chosen.badgeText(in: palette) == palette.chipSelectedText)
            #expect(ClarifyRowStyle.choice.badgeFill(in: palette) == nil)
            #expect(ClarifyRowStyle.choice.badgeText(in: palette) == palette.textSecondary)
        }
    }

    @Test func pickedBadgeFollowsTheAskingBotsAccent() throws {
        let accent = try #require(BotAccent(name: "Atlas", uiMeta: nil))
        for palette in Self.palettes {
            #expect(ClarifyRowStyle.chosen.badgeFill(in: palette, accent: accent) == .botAccent(accent))
            #expect(ClarifyRowStyle.chosen.badgeText(in: palette, accent: accent) == .botAccent(accent))
        }
    }

    @Test func aBotWithoutAnAccentKeepsTheNeutralSelectedFill() {
        for palette in Self.palettes {
            #expect(ClarifyRowStyle.chosen.badgeFill(in: palette, accent: nil) == .palette(palette.chipSelectedFill))
            #expect(ClarifyRowStyle.chosen.badgeText(in: palette, accent: nil) == .palette(palette.chipSelectedText))
        }
    }

    @Test func restingBadgesStayNeutralWhateverTheAccent() throws {
        let accent = try #require(BotAccent(name: "Atlas", uiMeta: nil))
        for palette in Self.palettes {
            #expect(ClarifyRowStyle.choice.badgeFill(in: palette, accent: accent) == nil)
            #expect(ClarifyRowStyle.choice.badgeText(in: palette, accent: accent) == .palette(palette.textSecondary))
        }
    }
}
