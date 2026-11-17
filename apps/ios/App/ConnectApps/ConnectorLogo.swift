import PalConnect
import PalDesign
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum ConnectorLogo {
    static let namespace = "ConnectorLogos"

    static func image(for app: ConnectApp) -> Image? {
        guard case .catalog(let entry) = app.source else { return nil }
        return image(named: entry.icon)
    }

    static func image(named id: String) -> Image? {
        let name = "\(namespace)/\(id)"
        guard !id.isEmpty, exists(name) else { return nil }
        return Image(name).resizable()
    }

    private static func exists(_ name: String) -> Bool {
        #if canImport(UIKit)
        UIImage(named: name) != nil
        #else
        NSImage(named: name) != nil
        #endif
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
