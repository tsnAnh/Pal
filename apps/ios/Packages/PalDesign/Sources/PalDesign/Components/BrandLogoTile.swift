import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The one white tile every third-party brand mark sits on (model providers today, connector apps next).
///
/// The tile is white in light and dark mode so a vendored logo reads the same everywhere, has no stroke,
/// and carries only a very soft shadow so it lifts off a near-white sheet. Callers pass the catalogue
/// name of a vector logo and a monogram; a name with no image in the catalogue draws the monogram in
/// near-black ink instead. Sizes: 34 pt in provider rows, 40 pt for connectors, 64 pt as a dialog hero.
/// Reuse this tile for any new brand logo instead of drawing another; `BrandLogoTileMetrics` holds every number.
public enum BrandLogoTileSize: Sendable, Equatable {
    case row
    case connector
    case hero

    public var points: CGFloat {
        switch self {
        case .row: BrandLogoTileMetrics.rowSize
        case .connector: BrandLogoTileMetrics.connectorSize
        case .hero: BrandLogoTileMetrics.heroSize
        }
    }
}

public enum BrandLogoTileMetrics {
    public static let rowSize: CGFloat = 34
    public static let connectorSize: CGFloat = 40
    public static let heroSize: CGFloat = 64
    public static let logoPaddingRatio: CGFloat = 0.22
    public static let cornerRadiusRatio: CGFloat = ConnectRowMetrics.tileRadius / ConnectRowMetrics.tileSize
    public static let monogramSizeRatio: CGFloat = 0.38
    public static let shadowRadius: CGFloat = 3
    public static let shadowOffset: CGFloat = 1
    public static let shadowOpacity: Double = 0.12
    public static let inkHex: UInt32 = 0x111111
    public static let tileHex: UInt32 = 0xFFFFFF

    public static func cornerRadius(for size: CGFloat) -> CGFloat { size * cornerRadiusRatio }
    public static func logoPadding(for size: CGFloat) -> CGFloat { size * logoPaddingRatio }
}

public enum BrandMonogram {
    public static func initials(from name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard let first = words.first else { return "?" }
        let letters = words.count > 1 ? [first.first, words[1].first].compactMap { $0 } : Array(first.prefix(2))
        return String(letters).uppercased()
    }
}

public struct BrandLogoTile: View {
    private enum Content {
        case asset(String, monogram: String)
        case symbol(String)
    }

    private let content: Content
    private let size: BrandLogoTileSize

    public init(asset: String?, monogram: String, size: BrandLogoTileSize = .row) {
        content = .asset(asset ?? "", monogram: monogram)
        self.size = size
    }

    public init(symbol: String, size: BrandLogoTileSize = .row) {
        content = .symbol(symbol)
        self.size = size
    }

    private static let ink = Color(red: Double((BrandLogoTileMetrics.inkHex >> 16) & 255) / 255,
                                   green: Double((BrandLogoTileMetrics.inkHex >> 8) & 255) / 255,
                                   blue: Double(BrandLogoTileMetrics.inkHex & 255) / 255)

    public var body: some View {
        let points = size.points
        let shape = RoundedRectangle(cornerRadius: BrandLogoTileMetrics.cornerRadius(for: points), style: .continuous)
        glyph(points)
            .frame(width: points, height: points)
            .background(Color.white, in: shape)
            .shadow(
                color: .black.opacity(BrandLogoTileMetrics.shadowOpacity),
                radius: BrandLogoTileMetrics.shadowRadius, y: BrandLogoTileMetrics.shadowOffset
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func glyph(_ points: CGFloat) -> some View {
        switch content {
        case .asset(let name, let monogram):
            if Self.hasImage(named: name) {
                Image(name)
                    .resizable()
                    .scaledToFit()
                    .padding(BrandLogoTileMetrics.logoPadding(for: points))
            } else {
                Text(monogram)
                    .font(.system(size: points * BrandLogoTileMetrics.monogramSizeRatio, weight: .semibold))
                    .foregroundStyle(Self.ink)
            }
        case .symbol(let name):
            PalIcon(name)
                .font(.system(size: points * BrandLogoTileMetrics.monogramSizeRatio * 1.1, weight: .regular))
                .environment(\.hermesTheme, PalTheme(mode: .light, palette: .derivedLight))
        }
    }

    private static func hasImage(named name: String) -> Bool {
        guard !name.isEmpty else { return false }
        #if canImport(AppKit)
        return NSImage(named: name) != nil
        #else
        return UIImage(named: name) != nil
        #endif
    }
}
