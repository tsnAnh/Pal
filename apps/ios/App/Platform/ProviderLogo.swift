import PalBotProfile
import PalDesign
import SwiftUI

enum ProviderLogo {
    static let localSymbol = "desktopcomputer"

    static func tile(for id: String, name: String, size: BrandLogoTileSize = .row) -> BrandLogoTile {
        if id == FirstRunProviders.localProviderID {
            return BrandLogoTile(symbol: localSymbol, size: size)
        }
        return BrandLogoTile(asset: "ProviderLogos/\(id)", monogram: BrandMonogram.initials(from: name), size: size)
    }
}
