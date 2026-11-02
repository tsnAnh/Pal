import Foundation
import Testing
@testable import HermesDesign

private let matrix = ParityMatrix.shared

@Suite("Color syntax, eye rule and hashing match the desktop")
struct DesktopSemanticsTests {
    @Test("safeAvatarColor accepts and rejects exactly what the desktop does", arguments: matrix.colors)
    func colorSyntax(golden: ParityMatrix.ColorGolden) {
        let parsed = AvatarColor(css: golden.input)
        #expect((parsed != nil) == (golden.safe != nil), "\(golden.input.debugDescription)")
        guard let parsed, let safe = golden.safe else { return }
        #expect(parsed.css == safe)
        #expect(parsed.isDark == golden.dark, "\(golden.input.debugDescription) dark")
        #expect(parsed.eyeFillCSS == golden.eye, "\(golden.input.debugDescription) eye")
    }

    @Test("profileColor and defaultShapeFor hash identically, including unicode, empty and NaN-looking names", arguments: matrix.names)
    func nameHashing(golden: ParityMatrix.NameGolden) {
        #expect(AvatarNaming.profileColor(golden.name) == golden.profileColor, "\(golden.name.debugDescription)")
        #expect(AvatarNaming.defaultShape(for: golden.name).rawValue == golden.defaultShape, "\(golden.name.debugDescription)")
    }

    @Test("nil name hashes like the empty string")
    func nilName() {
        #expect(AvatarNaming.profileColor(nil) == nil)
    }

    @Test("shape strings parse to the same seed and silhouette, unknown kinds fall away", arguments: matrix.shapes)
    func shapeGrammar(golden: ParityMatrix.ShapeGolden) {
        #expect(BlobShapeString.isBlob(golden.shape) == golden.isBlob, "\(golden.shape.debugDescription)")
        guard golden.isBlob else { return }
        let parsed = BlobShapeString.parse(golden.shape, name: golden.name)
        #expect(parsed.seed == golden.seed, "\(golden.shape.debugDescription) seed")
        #expect(parsed.seedPart == golden.seedPart)
        #expect((parsed.kind?.rawValue ?? "") == golden.kind, "\(golden.shape.debugDescription) kind")
    }

    @Test("blobatar figures are byte-identical to the library markup", arguments: ParityMatrix.figures)
    func figureMarkup(golden: ParityMatrix.FigureGolden) {
        let figure = BlobFigure(seed: golden.seed, shapeTrait: golden.shapeTrait)
        #expect(figure.silhouette.rawValue == golden.silhouette, "\(golden.seed.debugDescription)")
        #expect(figure.svgMarkup == golden.svg, "\(golden.seed.debugDescription) trait \(String(describing: golden.shapeTrait))")
    }

    @Test("accent and readable foreground match bot-accent.ts", arguments: matrix.accents)
    func accents(golden: ParityMatrix.AccentGolden) {
        let meta = BotAvatarMeta(color: golden.meta.color, custom: golden.meta.custom ?? false)
        let accent = BotAccent(name: golden.name, meta: meta)
        #expect(accent?.accentHex == golden.accent, "\(golden.name) \(String(describing: golden.meta.color))")
        #expect(accent?.foregroundHex == golden.foreground)
    }
}

@Suite("Boundary parsing never produces an illegal avatar")
struct SpecParsingTests {
    @Test("every matrix case resolves to the desktop's kind, seed, fill and color", arguments: matrix.cases)
    func resolvedMatchesDesktop(testCase: ParityMatrix.Case) {
        let spec = BotAvatarSpec(name: testCase.name, uiMeta: testCase.uiMeta, photo: nil)
        let resolved = testCase.resolved

        switch spec {
        case .photo:
            #expect(resolved.kind == "photo" && testCase.meta.imageKind == "photo", "\(testCase.id)")
        case .shape(.blob(let blob)) where resolved.kind == "photo":
            #expect(testCase.meta.imageKind == "shape", "\(testCase.id): only a rasterized backfill is rendered as vector")
            #expect(blob.seed == testCase.name)
        case .shape(.blob(let blob)):
            #expect(resolved.kind == "blob", "\(testCase.id)")
            #expect(blob.seed == resolved.seed, "\(testCase.id) seed")
            #expect((blob.kind?.rawValue ?? "") == resolved.pinnedKind, "\(testCase.id) kind")
            #expect(blob.isCustomBody == resolved.customBody, "\(testCase.id) customBody")
            #expect(blob.headFillCSS == resolved.headFill, "\(testCase.id) head")
            #expect(blob.eyeFillCSS == resolved.eyeFill, "\(testCase.id) eye")
        case .shape(.classic(let classic)):
            #expect(resolved.kind == "classic", "\(testCase.id)")
            #expect(classic.color.css == resolved.color, "\(testCase.id) color")
            #expect(classic.eyeFillCSS == resolved.eyeFill, "\(testCase.id) eye")
        case .shape(.sigil(let sigil)):
            #expect(resolved.kind == "sigil", "\(testCase.id)")
            #expect(sigil.color.css == resolved.color, "\(testCase.id) color")
        }
    }

    @Test("photo bytes plus imageKind photo is the only way to get a photo")
    func photoRules() {
        let bytes = Data([0x89, 0x50, 0x4e, 0x47])
        let photoMeta: [String: Any] = ["hermes-bots": ["imageKind": "photo", "shape": "circle", "color": "#e5484d"]]
        let shapeMeta: [String: Any] = ["hermes-bots": ["imageKind": "shape", "shape": "circle", "color": "#e5484d"]]

        guard case .photo(let photo) = BotAvatarSpec(name: "p", uiMeta: photoMeta, photo: bytes) else {
            Issue.record("photo bytes with imageKind photo should be a photo")
            return
        }
        #expect(photo.data == bytes)
        guard case .classic(let fallback) = photo.fallback else {
            Issue.record("the photo keeps the shape avatar as its fallback")
            return
        }
        #expect(fallback.shape == .circle)

        #expect(BotAvatarSpec(name: "p", uiMeta: photoMeta, photo: nil).isPhoto == false)
        #expect(BotAvatarSpec(name: "p", uiMeta: photoMeta, photo: Data()).isPhoto == false)
        #expect(BotAvatarSpec(name: "p", uiMeta: shapeMeta, photo: bytes).isPhoto == false)
    }

    @Test("an embedded data URL supplies photo bytes when none are passed")
    func dataURLPhoto() {
        let payload = Data([1, 2, 3, 4, 5]).base64EncodedString()
        let meta: [String: Any] = ["hermes-bots": ["imageKind": "photo", "image": "data:image/png;base64,\(payload)"]]
        guard case .photo(let photo) = BotAvatarSpec(name: "p", uiMeta: meta, photo: nil) else {
            Issue.record("a base64 data URL with imageKind photo should be a photo")
            return
        }
        #expect(photo.data == Data([1, 2, 3, 4, 5]))

        let broken: [String: Any] = ["hermes-bots": ["imageKind": "photo", "image": "data:image/png;base64,@@@"]]
        #expect(BotAvatarSpec(name: "p", uiMeta: broken, photo: nil).isPhoto == false)
        let remote: [String: Any] = ["hermes-bots": ["imageKind": "photo", "image": "https://example.com/a.png"]]
        #expect(BotAvatarSpec(name: "p", uiMeta: remote, photo: nil).isPhoto == false)
    }

    @Test("malformed ui_meta falls back to the name-derived avatar instead of failing")
    func malformedMeta() {
        let reference = BotAvatarSpec(name: "alice", uiMeta: nil, photo: nil)
        let malformed: [[String: Any]] = [
            ["hermes-bots": "nope"],
            ["hermes-bots": 12],
            ["hermes-bots": ["shape": 7, "color": 9, "custom": "yes", "image": 3]],
            ["hermes-bots": ["shape": NSNull(), "color": NSNull()]],
            ["hermes-bots": [:] as [String: Any]],
            [:],
        ]
        for meta in malformed {
            #expect(BotAvatarSpec(name: "alice", uiMeta: meta, photo: nil) == reference, "\(meta)")
        }
    }

    @Test("a custom flag given as a non-boolean does not unlock the primary bot")
    func primaryBotStaysSquircle() {
        for flag in [true, false] {
            let meta: [String: Any] = ["hermes-bots": ["custom": flag, "shape": "circle", "color": "#e5484d"]]
            let spec = BotAvatarSpec(name: "  Default ", uiMeta: meta, photo: nil)
            guard case .shape(.classic(let classic)) = spec else {
                Issue.record("expected classic")
                continue
            }
            #expect((classic.shape == .circle) == flag)
            #expect((classic.color.css == "#e5484d") == flag)
            if !flag {
                #expect(classic.shape == .squircle)
                #expect(classic.color.css == "#8b5cf6")
            }
        }
        let stringFlag: [String: Any] = ["hermes-bots": ["custom": "true", "shape": "circle"]]
        guard case .shape(.classic(let classic)) = BotAvatarSpec(name: "default", uiMeta: stringFlag, photo: nil) else {
            Issue.record("expected classic")
            return
        }
        #expect(classic.shape == .squircle)
    }

    @Test("sigil seeds follow Number() semantics for integers and degrade to zero otherwise")
    func sigilSeeds() {
        let cases: [(String, Int)] = [
            ("sigil-3", 3), ("sigil-0", 0), ("sigil-", 0), ("sigil-x", 0), ("sigil--2", -2), ("sigil-+4", 4),
            ("sigil- 5 ", 5), ("sigil-0x10", 16), ("sigil-1e2", 100), ("sigil-007", 7),
            ("sigil-99999999999999999999999", 0), ("sigil-NaN", 0), ("sigil-Infinity", 0), ("sigil--0", 0),
        ]
        for (shape, expected) in cases {
            let meta: [String: Any] = ["hermes-bots": ["shape": shape]]
            guard case .shape(.sigil(let sigil)) = BotAvatarSpec(name: "n", uiMeta: meta, photo: nil) else {
                Issue.record("\(shape) should be a sigil")
                continue
            }
            #expect(sigil.seed == expected, "\(shape)")
        }
    }

    @Test("blob grammar edge cases")
    func blobGrammar() {
        let parsed = BlobShapeString.parse("blobatar:seed:bogus", name: "named")
        #expect(parsed.kind == nil)
        #expect(parsed.seed == "seed")
        #expect(BlobShapeString.parse("blobatar", name: "").seed == "agent")
        #expect(BlobShapeString.parse("blobatar::boxy", name: "n").kind == .boxy)
        #expect(BlobShapeString.parse("blobatar::boxy", name: "n").seed == "n")
        #expect(BlobShapeString.isBlob("blobatarx") == false)
        #expect(BlobShapeString.isBlob("Blobatar") == false)
    }
}
