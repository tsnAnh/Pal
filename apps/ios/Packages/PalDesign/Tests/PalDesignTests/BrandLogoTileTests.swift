import CoreGraphics
@testable import PalDesign
import Testing

@Suite("Brand logo tile")
struct BrandLogoTileTests {
    @Test func theThreeSizesAreProviderRowConnectorAndHero() {
        #expect(BrandLogoTileSize.row.points == 34)
        #expect(BrandLogoTileSize.connector.points == 40)
        #expect(BrandLogoTileSize.hero.points == 64)
    }

    @Test func theTileIsWhiteWithTheConnectRowCornerRatio() {
        #expect(BrandLogoTileMetrics.tileHex == 0xFFFFFF)
        #expect(BrandLogoTileMetrics.cornerRadiusRatio == ConnectRowMetrics.tileRadius / ConnectRowMetrics.tileSize)
        #expect(BrandLogoTileMetrics.cornerRadius(for: BrandLogoTileSize.connector.points) == ConnectRowMetrics.tileRadius)
    }

    @Test func theLogoSitsAtTwentyTwoPercentPadding() {
        #expect(BrandLogoTileMetrics.logoPadding(for: 100) == 22)
    }

    @Test func theShadowStaysSoftAndInsideThePerfBudget() {
        #expect(BrandLogoTileMetrics.shadowRadius < 24)
        #expect(BrandLogoTileMetrics.shadowOpacity <= 0.15)
    }

    @Test func thePluginPuzzleIsTheConnectorSizedBrandTileSymbol() {
        #expect(PluginGlyphTile.symbol == "puzzlepiece.extension")
        #expect(BrandLogoTileSize.connector.points == ConnectRowMetrics.tileSize)
    }

    @Test func monogramInkIsNearBlackNotTheThemeInk() {
        #expect(BrandLogoTileMetrics.inkHex == 0x111111)
    }

    @Test func initialsTakeTwoWordsOrTheFirstTwoLetters() {
        for expected in MonogramCases.expectations {
            #expect(BrandMonogram.initials(from: expected.name) == expected.initials)
        }
    }

    @Test func aNameWithNoLettersFallsBackToAQuestionMark() {
        #expect(BrandMonogram.initials(from: "  ") == "?")
    }
}

private enum MonogramCases {
    static let expectations: [(name: String, initials: String)] = [
        ("GMI Cloud", "GC"), ("Solstice", "SO"), ("Actual", "AC"), ("Nous Portal", "NP"), ("router", "RO"), ("Z.AI / GLM", "ZA"),
    ]
}
