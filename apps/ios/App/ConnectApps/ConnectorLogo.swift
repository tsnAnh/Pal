import PalConnect
import PalDesign
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
final class ConnectorLogoCache {
    static let shared = ConnectorLogoCache { name in
        #if canImport(UIKit)
        UIImage(named: name) != nil
        #else
        NSImage(named: name) != nil
        #endif
    }

    private let exists: (String) -> Bool
    private var known: [String: Bool] = [:]
    private(set) var lookups = 0

    init(exists: @escaping (String) -> Bool) {
        self.exists = exists
    }

    func hasImage(named name: String) -> Bool {
        if let cached = known[name] { return cached }
        lookups += 1
        let found = exists(name)
        known[name] = found
        return found
    }
}

@MainActor
enum ConnectorLogo {
    static let namespace = "ConnectorLogos"

    static func assetName(_ id: String) -> String { "\(namespace)/\(id)" }
}

struct ConnectorLogoTile: View {
    let app: ConnectApp

    var body: some View {
        switch app.tileMark {
        case .logo(let id):
            let name = ConnectorLogo.assetName(id)
            BrandLogoTile(
                asset: ConnectorLogoCache.shared.hasImage(named: name) ? name : nil,
                monogram: BrandMonogram.initials(from: app.name), size: .connector
            )
        case .puzzle:
            PluginGlyphTile()
        }
    }
}
