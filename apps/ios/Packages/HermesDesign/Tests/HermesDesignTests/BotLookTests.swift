import Foundation
import Testing
@testable import HermesDesign

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
        #expect(look.kind == BotLook.defaultKind)
        #expect(look.colorHex.hasPrefix("#"))
    }

    @Test("classic and unknown shapes fall back to the default kind")
    func nonBlob() {
        #expect(BotLook(name: "a", shape: "hexagon", color: nil).kind == BotLook.defaultKind)
        #expect(BotLook(name: "a", shape: "blobatar:a:nonsense", color: nil).kind == BotLook.defaultKind)
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
}
