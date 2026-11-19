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

    static func image(for app: ConnectApp) -> Image? {
        guard case .catalog(let entry) = app.source else { return nil }
        return image(named: entry.icon)
    }

    static func image(named id: String) -> Image? {
        let name = "\(namespace)/\(id)"
        guard !id.isEmpty, ConnectorLogoCache.shared.hasImage(named: name) else { return nil }
        return Image(name).resizable()
    }
}

struct ConnectorLogoTile: View {
    let app: ConnectApp

    var body: some View {
        if let logo = ConnectorLogo.image(for: app) {
            AppTile { logo.scaledToFit().padding(ConnectRowMetrics.tileSize * 0.22) }
        } else {
            PluginGlyphTile()
        }
    }
}
