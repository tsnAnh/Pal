import Foundation
import Testing
@testable import PalDesign

@Suite("Bot look editing")
struct BotLookTests {
    @Test("a stored blob look round-trips seed, kind and colour")
    func roundTrip() {
        let look = BotLook(name: "cho-ua", shape: "blobatar:ua:organic", color: "#d6264a")
        #expect(look.seed == "ua")
        #expect(look.kind == .organic)
        #expect(look.colorHex == "#d6264a")
        #expect(look.shapeString == "blobatar:ua:organic")
    }

    @Test("a bot without a blob look starts from the default kind and its own name")
    func defaults() {
        let look = BotLook(name: "market-researcher", shape: nil, color: nil)
        #expect(look.seed == "market-researcher")
        #expect(look.kind == BotLookCatalog.defaultShape)
        #expect(look.colorHex.hasPrefix("#"))
    }

    @Test("classic and unknown shapes fall back to the default kind")
    func nonBlob() {
        #expect(BotLook(name: "a", shape: "hexagon", color: nil).kind == BotLookCatalog.defaultShape)
        #expect(BotLook(name: "a", shape: "blobatar:a:nonsense", color: nil).kind == BotLookCatalog.defaultShape)
    }

    @Test("an hsl colour is stored as a hex swatch")
    func hslColour() {
        #expect(BotLook(name: "a", shape: nil, color: "hsl(0 100% 50%)").colorHex == "#ff0000")
    }

    @Test("the edited look builds a custom blob avatar spec")
    func spec() {
        var look = BotLook(name: "a", shape: "blobatar:a:round", color: "#ffffff")
        look.kind = .cloud
        look.colorHex = "#10dc69"
        guard case .shape(.blob(let blob)) = look.spec else {
            Issue.record("expected a blob spec")
            return
        }
        #expect(blob.kind == .cloud)
        #expect(blob.isCustomBody)
    }

    @Test("a random look uses a catalog kind and swatch with an eight character seed that survives the stored shape string")
    func randomLook() {
        var first = SystemRandomNumberGenerator()
        let look = BotLook.random(using: &first)
        #expect(look.seed.count == 8)
        #expect(BotLookCatalog.shapes.contains(look.kind))
        #expect(BotLookCatalog.swatches.contains { $0.hex == look.colorHex })
        #expect(BotLook(name: "x", shape: look.shapeString, color: look.colorHex) == BotLook(seed: look.seed, kind: look.kind, colorHex: look.colorHex))
    }
}

@Suite("Bot look grid keys")
struct BotLookGridTests {
    private let shapes = BotLookCatalog.shapeRowLengths
    private let swatches = BotLookCatalog.swatchRowLengths

    @Test("the catalog rows are 5, 5, 4 shapes and 6, 5 colours")
    func rowLengths() {
        #expect(shapes == [5, 5, 4])
        #expect(swatches == [6, 5])
    }

    @Test("left and right stay inside their row and stop at its edges")
    func horizontal() {
        #expect(BotLookCatalog.move(0, .left, rowLengths: shapes) == 0)
        #expect(BotLookCatalog.move(4, .right, rowLengths: shapes) == 4)
        #expect(BotLookCatalog.move(5, .left, rowLengths: shapes) == 5)
        #expect(BotLookCatalog.move(9, .right, rowLengths: shapes) == 9)
        #expect(BotLookCatalog.move(13, .right, rowLengths: shapes) == 13)
        #expect(BotLookCatalog.move(12, .right, rowLengths: shapes) == 13)
        #expect(BotLookCatalog.move(2, .right, rowLengths: shapes) == 3)
        #expect(BotLookCatalog.move(7, .left, rowLengths: shapes) == 6)
        #expect(BotLookCatalog.move(5, .right, rowLengths: swatches) == 5)
        #expect(BotLookCatalog.move(6, .left, rowLengths: swatches) == 6)
    }

    @Test("up and down keep the column and clamp to the shorter last row")
    func vertical() {
        #expect(BotLookCatalog.move(2, .up, rowLengths: shapes) == 2)
        #expect(BotLookCatalog.move(2, .down, rowLengths: shapes) == 7)
        #expect(BotLookCatalog.move(7, .down, rowLengths: shapes) == 12)
        #expect(BotLookCatalog.move(9, .down, rowLengths: shapes) == 13)
        #expect(BotLookCatalog.move(10, .down, rowLengths: shapes) == 10)
        #expect(BotLookCatalog.move(12, .up, rowLengths: shapes) == 7)
        #expect(BotLookCatalog.move(10, .up, rowLengths: shapes) == 5)
        #expect(BotLookCatalog.move(5, .up, rowLengths: shapes) == 0)
    }

    @Test("colour rows move between the 6 and 5 rows and clamp the sixth column")
    func colourRows() {
        #expect(BotLookCatalog.move(1, .down, rowLengths: swatches) == 7)
        #expect(BotLookCatalog.move(5, .down, rowLengths: swatches) == 10)
        #expect(BotLookCatalog.move(10, .up, rowLengths: swatches) == 4)
        #expect(BotLookCatalog.move(10, .down, rowLengths: swatches) == 10)
        #expect(BotLookCatalog.move(0, .up, rowLengths: swatches) == 0)
    }

    @Test("an index outside the grid lands on its nearest cell")
    func outOfRange() {
        #expect(BotLookCatalog.move(-4, .right, rowLengths: shapes) == 1)
        #expect(BotLookCatalog.move(99, .left, rowLengths: shapes) == 12)
        #expect(BotLookCatalog.move(0, .right, rowLengths: []) == 0)
    }

    @Test("VoiceOver reads a shape and a colour with their place in the catalog")
    func labels() {
        #expect(BotLookCatalog.shapeAccessibilityLabel(.boxy, isSelected: true) == "Shape 3 of 14, Squircle, selected")
        #expect(BotLookCatalog.shapeAccessibilityLabel(.round, isSelected: false) == "Shape 1 of 14, Round")
        let orange = BotLookCatalog.swatches[4]
        #expect(BotLookCatalog.swatchAccessibilityLabel(orange, isSelected: true) == "Colour Orange, 5 of 11, selected")
        #expect(BotLookCatalog.swatchAccessibilityLabel(BotLookCatalog.swatches[10], isSelected: false) == "Colour Gray, 11 of 11")
    }
}
