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
