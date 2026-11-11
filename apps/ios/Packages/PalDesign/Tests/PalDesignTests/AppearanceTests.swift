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
        for mode in [AppearanceMode.dark, .black, .botColor] {
            #expect(mode.preferredColorScheme == .dark)
        }
    }

    @Test("follow-system picks the palette of the system scheme")
    func followSystemPalette() {
        #expect(AppearanceMode.followSystem.palette(systemScheme: .dark, botAccent: nil) == PalPalette.measuredDark)
        #expect(AppearanceMode.followSystem.palette(systemScheme: .light, botAccent: nil) == PalPalette.derivedLight)
    }

    @Test("the five modes give five distinct canvases when a bot accent exists")
    func distinctCanvases() throws {
        let accent = try #require(RGB(hexString: "#8b5cf6"))
        let canvases = Set(AppearanceMode.allCases.filter { $0 != .followSystem }.map {
            $0.palette(systemScheme: .dark, botAccent: accent).canvas
        })
        #expect(canvases.count == 4)
        #expect(AppearanceMode.black.palette(systemScheme: .dark, botAccent: nil).canvas.hex == 0x000000)
    }

    @Test("bot color tints surfaces toward the accent hue and leaves text alone")
    func botColorTint() throws {
        let accent = try #require(RGB(hexString: "#f43f5e"))
        let tinted = AppearanceMode.botColor.palette(systemScheme: .dark, botAccent: accent)
        let plain = PalPalette.measuredDark
        #expect(tinted.canvas != plain.canvas)
        #expect(tinted.groupedCard != plain.groupedCard)
        let tintedHue = tinted.groupedCard.hueSaturationBrightness
        let accentHue = accent.hueSaturationBrightness
        #expect(abs(tintedHue.hue - accentHue.hue) < 0.02)
        #expect(tintedHue.saturation > 0.05)
        #expect(tinted.textPrimary == plain.textPrimary)
        #expect(tinted.accentBlue == plain.accentBlue)
    }

    @Test("bot color without an accent is the dark palette")
    func botColorWithoutAccent() {
        #expect(AppearanceMode.botColor.palette(systemScheme: .dark, botAccent: nil) == PalPalette.measuredDark)
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
