import Foundation
import SwiftUI
import Testing
@testable import PalDesign

@Suite("Appearance modes resolve to the right palette and persist")
@MainActor
struct AppearanceTests {
    private func isolatedDefaults() -> UserDefaults {
        let name = "appearance-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("a fresh install follows the system")
    func defaultsToFollowSystem() {
        #expect(AppearanceStore(defaults: isolatedDefaults()).mode == .followSystem)
    }

    @Test("every mode survives a relaunch", arguments: AppearanceMode.allCases)
    func persistsAcrossStores(mode: AppearanceMode) {
        let defaults = isolatedDefaults()
        AppearanceStore(defaults: defaults).mode = mode
        #expect(AppearanceStore(defaults: defaults).mode == mode)
    }

    @Test("a stored value from a newer build falls back to following the system")
    func unknownStoredValueFallsBack() {
        let defaults = isolatedDefaults()
        defaults.set("sepia", forKey: AppearanceStore.defaultsKey)
        #expect(AppearanceStore(defaults: defaults).mode == .followSystem)
    }

    @Test("only follow-system leaves the color scheme to the system")
    func colorSchemeMapping() {
        #expect(AppearanceMode.followSystem.preferredColorScheme == nil)
        #expect(AppearanceMode.light.preferredColorScheme == .light)
        for mode in [AppearanceMode.dark, .black] {
            #expect(mode.preferredColorScheme == .dark)
        }
    }

    @Test("follow-system picks the palette of the system scheme")
    func followSystemPalette() {
        #expect(AppearanceMode.followSystem.palette(systemScheme: .dark) == PalPalette.measuredDark)
        #expect(AppearanceMode.followSystem.palette(systemScheme: .light) == PalPalette.derivedLight)
    }

    @Test("the explicit modes give distinct canvases")
    func distinctCanvases() {
        let canvases = Set(AppearanceMode.allCases.filter { $0 != .followSystem }.map {
            $0.palette(systemScheme: .dark).canvas
        })
        #expect(canvases.count == 3)
        #expect(AppearanceMode.black.palette(systemScheme: .dark).canvas.hex == 0x000000)
    }

    @Test("an install that stored the removed bot color mode follows the system")
    func removedBotColorMigrates() {
        let defaults = isolatedDefaults()
        defaults.set("botColor", forKey: AppearanceStore.defaultsKey)
        #expect(AppearanceStore(defaults: defaults).mode == .followSystem)
    }

    @Test("hex parsing round-trips and rejects malformed input")
    func hexParsing() {
        #expect(RGB(hexString: "#272729")?.hexString == "#272729")
        #expect(RGB(hexString: "272729")?.hex == 0x272729)
        #expect(RGB(hexString: "#27272") == nil)
        #expect(RGB(hexString: "#zzzzzz") == nil)
    }

    @Test("hue, saturation and brightness round-trip")
    func hsbRoundTrip() {
        for hex: UInt32 in [0x8b5cf6, 0x1c65cb, 0xf58903, 0x141414, 0xffffff] {
            let color = RGB(hex: hex)
            let parts = color.hueSaturationBrightness
            let rebuilt = RGB(hue: parts.hue, saturation: parts.saturation, brightness: parts.brightness)
            #expect(rebuilt.hex == hex)
        }
    }
}
