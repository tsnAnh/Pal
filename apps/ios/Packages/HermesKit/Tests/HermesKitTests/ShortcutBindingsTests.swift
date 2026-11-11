import Foundation
import HermesSettings
import Testing

@Suite("Shortcut bindings")
struct ShortcutBindingsTests {
    private let cmdJ = KeyChord(key: "j", modifiers: .command)

    @Test func defaultsAreUniqueAndAllowed() {
        let chords = ShortcutAction.allCases.map(\.defaultChord)
        #expect(Set(chords).count == chords.count)
        for chord in chords { #expect(ChordPolicy.check(chord) == .ok) }
    }

    @Test func encodeDecodeRoundTripKeepsOverridesAndClears() {
        var bindings = ShortcutBindings()
        bindings.assign(cmdJ, to: .newBot)
        bindings.clear(.search)
        let decoded = ShortcutBindings(decoding: bindings.encoded())
        #expect(decoded == bindings)
        #expect(decoded.chord(for: .newBot) == cmdJ)
        #expect(decoded.chord(for: .search) == nil)
        #expect(decoded.chord(for: .settings) == ShortcutAction.settings.defaultChord)
    }

    @Test func corruptOrUnknownDataFallsBackToDefaults() {
        #expect(ShortcutBindings(decoding: Data("nope".utf8)) == ShortcutBindings())
        #expect(ShortcutBindings(decoding: nil) == ShortcutBindings())
        let unknown = Data(#"{"bogus":{"cleared":{}}}"#.utf8)
        #expect(ShortcutBindings(decoding: unknown) == ShortcutBindings())
    }

    @Test func storedReservedChordIsDropped() {
        var bindings = ShortcutBindings()
        bindings.assign(cmdJ, to: .newBot)
        let reserved = KeyChord(key: "q", modifiers: .command)
        let json = String(decoding: bindings.encoded() ?? Data(), as: UTF8.self)
            .replacingOccurrences(of: "\"j\"", with: "\"q\"")
        let decoded = ShortcutBindings(decoding: Data(json.utf8))
        #expect(decoded.chord(for: .newBot) == ShortcutAction.newBot.defaultChord)
        #expect(decoded.chord(for: .newBot) != reserved)
    }

    @Test func conflictNamesTheOtherAction() {
        let bindings = ShortcutBindings()
        let taken = ShortcutAction.search.defaultChord
        #expect(bindings.occupant(of: taken, excluding: .newBot) == .action(.search))
        #expect(bindings.occupant(of: taken, excluding: .search) == nil)
        #expect(bindings.occupant(of: KeyChord(key: "3", modifiers: .command), excluding: .newBot) == .goToBot)
        #expect(bindings.occupant(of: cmdJ, excluding: .newBot) == nil)
    }

    @Test func replacingClearsTheOtherAction() {
        var bindings = ShortcutBindings()
        bindings.assign(ShortcutAction.search.defaultChord, to: .newBot)
        #expect(bindings.chord(for: .newBot) == ShortcutAction.search.defaultChord)
        #expect(bindings.chord(for: .search) == nil)
    }

    @Test func resetRestoresDefaultPerActionAndForAll() {
        var bindings = ShortcutBindings()
        bindings.assign(cmdJ, to: .newBot)
        bindings.clear(.search)
        bindings.reset(.newBot)
        #expect(bindings.chord(for: .newBot) == ShortcutAction.newBot.defaultChord)
        #expect(bindings.hasCustomizations)
        bindings.resetAll()
        #expect(bindings == ShortcutBindings())
        #expect(!bindings.hasCustomizations)
    }

    @Test func assigningTheDefaultStoresNoOverride() {
        var bindings = ShortcutBindings()
        bindings.assign(cmdJ, to: .newBot)
        bindings.assign(ShortcutAction.newBot.defaultChord, to: .newBot)
        #expect(bindings.isDefault(.newBot))
    }

    @Test func modifierRules() {
        #expect(ChordPolicy.check(KeyChord(key: "j", modifiers: [])) == .refused(.needsModifier))
        #expect(ChordPolicy.check(KeyChord(key: "j", modifiers: .shift)) == .refused(.needsModifier))
        #expect(ChordPolicy.check(KeyChord(key: "j", modifiers: .option)) == .refused(.needsModifier))
        #expect(ChordPolicy.check(KeyChord(key: "up", modifiers: .shift)) == .refused(.needsModifier))
        #expect(ChordPolicy.check(KeyChord(key: "up", modifiers: .option)) == .ok)
        #expect(ChordPolicy.check(KeyChord(key: "f5", modifiers: [])) == .ok)
        #expect(ChordPolicy.check(KeyChord(key: "j", modifiers: .control)) == .ok)
    }

    @Test func systemReservedChordsAreRefusedAndCommonOnesWarn() {
        #expect(ChordPolicy.check(KeyChord(key: "q", modifiers: .command)) == .refused(.systemReserved("Quit")))
        #expect(ChordPolicy.check(KeyChord(key: "h", modifiers: .command)) == .refused(.systemReserved("Hide Pal")))
        #expect(ChordPolicy.check(KeyChord(key: "space", modifiers: .command)) == .refused(.systemReserved("Spotlight")))
        #expect(ChordPolicy.check(KeyChord(key: "w", modifiers: .command)) == .warning("Close Window"))
    }

    @Test func glyphsFollowMacOrderAndSpeechNamesTheKeys() {
        let chord = KeyChord(key: "k", modifiers: [.command, .shift, .option, .control])
        #expect(chord.glyphs == ["⌃", "⌥", "⇧", "⌘", "K"])
        #expect(chord.spoken == "Control Option Shift Command K")
        #expect(KeyChord(key: "up", modifiers: .option).glyphs == ["⌥", "↑"])
        #expect(KeyChord(key: "f12", modifiers: []).glyphs == ["F12"])
    }

    @Test func duplicateStoredChordsKeepTheExplicitOverride() throws {
        var stolen = ShortcutBindings()
        stolen.assign(ShortcutAction.search.defaultChord, to: .newBot)
        let data = try #require(stolen.encoded())
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "search")
        let decoded = ShortcutBindings(decoding: try JSONSerialization.data(withJSONObject: json))
        #expect(decoded.chord(for: .newBot) == ShortcutAction.search.defaultChord)
        #expect(decoded.chord(for: .search) == nil)
    }
}
