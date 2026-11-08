import Foundation

struct BlobFigure: Equatable {
    struct Eye: Equatable {
        var cx: Double
        var cy: Double
        var rx: Double
        var ry: Double
        var n: Double
        var rot: Double

        var path: String {
            BlobGeometry.superellipse(cx: cx, cy: cy, rx: rx, ry: ry, n: n, rot: rot)
        }
    }

    struct Petal: Equatable {
        var cx: Double
        var cy: Double
        var r: Double
    }

    let silhouette: BlobKind
    let petals: [Petal]
    let extraPaths: [String]
    let mainPath: String
    let eyes: [Eye]
    let palette: BlobPalette.Colors

    init(seed: String, shapeTrait: Double? = nil) {
        let overrides = shapeTrait.map { ["shape": $0] } ?? [:]
        let traits = BlobTraits(seed: seed, overrides: overrides)
        let layout = BlobLayout.make(traits)
        silhouette = layout.shape.kind
        petals = layout.petals
        extraPaths = layout.extra
        mainPath = layout.shape.path(layout.body)
        eyes = layout.eyes
        palette = BlobPalette.colors(hue: traits.num("hue", 0, 360), tone: traits("tone"))
    }

    init(seed: String, kind: BlobKind?) {
        guard let kind, kind.isExtended else {
            self.init(seed: seed, shapeTrait: kind?.traitPosition)
            return
        }
        let base = BlobFigure(seed: seed, shapeTrait: kind.traitPosition)
        guard let shape = ExtendedSilhouette(kind, aroundBody: base.mainPath) else {
            self = base
            return
        }
        self.init(
            silhouette: kind, petals: shape.petals, extraPaths: [], mainPath: shape.mainPath,
            eyes: base.eyes, palette: base.palette
        )
    }

    private init(
        silhouette: BlobKind, petals: [Petal], extraPaths: [String], mainPath: String, eyes: [Eye],
        palette: BlobPalette.Colors
    ) {
        self.silhouette = silhouette
        self.petals = petals
        self.extraPaths = extraPaths
        self.mainPath = mainPath
        self.eyes = eyes
        self.palette = palette
    }

    var svgMarkup: String {
        let r2 = JSCompat.numberString
        let rounded: (Double) -> String = { r2(JSCompat.round2($0)) }
        let circles = petals.map { "<circle cx=\"\(rounded($0.cx))\" cy=\"\(rounded($0.cy))\" r=\"\(rounded($0.r))\"/>" }.joined()
        let extras = extraPaths.map { "<path d=\"\($0)\"/>" }.joined()
        let body = "<g fill=\"\(palette.head)\">\(circles)\(extras)<path d=\"\(mainPath)\"/></g>"
        let eyeMarkup = "<g fill=\"\(palette.eye)\">" + eyes.map { "<path d=\"\($0.path)\"/>" }.joined() + "</g>"
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\">\(body)\(eyeMarkup)</svg>"
    }

    var bodyPathData: [String] {
        extraPaths + [mainPath]
    }
}
