#if os(macOS)
import HermesDesign
import HermesSettings
import SwiftUI

struct MacKeycap: View {
    let glyph: String

    var body: some View {
        Text(glyph)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(PalTokens.textSecondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 19, minHeight: 19)
            .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

private struct PendingShortcut: Equatable {
    let action: ShortcutAction
    let chord: KeyChord
    let occupant: ChordOccupant?
    let warning: String?
}

struct MacShortcutSettingsSection: View {
    @Environment(ShortcutStore.self) private var store
    @State private var recording: ShortcutAction?
    @State private var pending: PendingShortcut?
    @State private var refusal: (action: ShortcutAction, message: String)?
    @State private var confirmingRestore = false

    var body: some View {
        MacSectionPage(
            section: .shortcuts,
            accessory: {
                Button("Restore Defaults") { confirmingRestore = true }
                    .buttonStyle(.palPill)
                    .disabled(!store.bindings.hasCustomizations)
                    .accessibilityIdentifier("shortcutsRestoreDefaults")
            },
            content: {
                ForEach(ShortcutGroup.allCases) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        MacCaption(group.localizedTitle)
                        MacCard(identifier: "shortcutGroup-\(group.rawValue)") {
                            ForEach(actions(in: group)) { action in
                                row(action)
                            }
                        }
                    }
                }
                MacFootnote(
                    text: String(localized: "Click a shortcut, then press the new keys. Press Delete to clear it or Escape to cancel."),
                    identifier: "shortcutsHint"
                )
            }
        )
        .confirmationDialog("Restore all keyboard shortcuts to their defaults?", isPresented: $confirmingRestore) {
            Button("Restore Defaults", role: .destructive) {
                stopRecording()
                store.resetAll()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onDisappear { stopRecording() }
    }

    private func actions(in group: ShortcutGroup) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.group == group }
    }

    private func row(_ action: ShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(String(localized: action.localizedTitle))
                    .font(.system(size: 12))
                    .foregroundStyle(PalTokens.textPrimary)
                Spacer(minLength: 8)
                if !store.bindings.isDefault(action) {
                    Button { reset(action) } label: {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PalTokens.textSecondary)
                    .help(Text("Reset to default"))
                    .accessibilityLabel(Text("Reset \(String(localized: action.localizedTitle)) to default"))
                    .accessibilityIdentifier("shortcutReset-\(action.rawValue)")
                }
                recorderButton(action)
            }
            if let message = refusal, message.action == action {
                Text(message.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("shortcutRefusal-\(action.rawValue)")
            }
            if let pending, pending.action == action { conflictBar(pending) }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shortcutRow-\(action.rawValue)")
    }

    private func recorderButton(_ action: ShortcutAction) -> some View {
        let isRecording = recording == action
        return Button { toggleRecording(action) } label: {
            Group {
                if isRecording {
                    Text("Type shortcut").font(.system(size: 11)).foregroundStyle(PalTokens.textSecondary)
                } else if let chord = store.chord(for: action) {
                    HStack(spacing: 2) { ForEach(Array(chord.glyphs.enumerated()), id: \.offset) { MacKeycap(glyph: $0.element) } }
                } else {
                    Text("None").font(.system(size: 11)).foregroundStyle(PalTokens.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 96, minHeight: 24)
            .background(isRecording ? PalTokens.selected : PalTokens.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                if isRecording {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .background { if isRecording { MacShortcutRecorder { handle($0, for: action) } } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(store.accessibilityLabel(for: action)))
        .accessibilityHint(Text(isRecording ? "Press the new key combination" : "Click to record a new shortcut"))
        .accessibilityIdentifier("shortcutRecorder-\(action.rawValue)")
    }

    private func conflictBar(_ pending: PendingShortcut) -> some View {
        let name = pending.chord.glyphs.joined()
        let message: String
        let confirm: String
        if let occupant = pending.occupant {
            message = String(localized: "\(name) is already used by \(occupant.title). Replace it?")
            confirm = String(localized: "Replace")
        } else {
            message = String(localized: "\(name) is also \(pending.warning ?? ""). Use it anyway?")
            confirm = String(localized: "Use Anyway")
        }
        return HStack(spacing: 8) {
            Text(message).font(.system(size: 11)).foregroundStyle(PalTokens.textSecondary)
            Spacer(minLength: 8)
            Button("Cancel") { stopRecording() }.buttonStyle(.palPill(height: 22, fontSize: 11))
                .accessibilityIdentifier("shortcutConflictCancel")
            Button(confirm) {
                store.assign(pending.chord, to: pending.action)
                stopRecording()
            }
            .buttonStyle(.palPill(height: 22, fontSize: 11))
            .accessibilityIdentifier("shortcutConflictConfirm")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shortcutConflict-\(pending.action.rawValue)")
    }

    private func toggleRecording(_ action: ShortcutAction) {
        let wasRecording = recording == action
        stopRecording()
        if !wasRecording { recording = action }
    }

    private func stopRecording() {
        recording = nil
        pending = nil
        refusal = nil
    }

    private func reset(_ action: ShortcutAction) {
        stopRecording()
        store.reset(action)
    }

    private func handle(_ event: MacRecorderEvent, for action: ShortcutAction) {
        switch event {
        case .cancel:
            stopRecording()
        case .clear:
            store.clear(action)
            stopRecording()
        case .chord(let chord):
            evaluate(chord, for: action)
        }
    }

    private func evaluate(_ chord: KeyChord, for action: ShortcutAction) {
        refusal = nil
        pending = nil
        let name = chord.glyphs.joined()
        let check = ChordPolicy.check(chord)
        switch check {
        case .refused(.needsModifier):
            refusal = (action, String(localized: "Include ⌘, ⌃ or ⌥ with the key."))
        case .refused(.systemReserved(let reserved)):
            refusal = (action, String(localized: "\(name) is reserved by macOS for \(reserved). Choose another shortcut."))
        case .ok, .warning:
            let warning: String? = if case .warning(let text) = check { text } else { nil }
            let occupant = store.bindings.occupant(of: chord, excluding: action)
            if occupant == .goToBot {
                refusal = (action, String(localized: "\(name) is used by Go to Bot and can't be reassigned."))
            } else if occupant != nil || warning != nil {
                pending = PendingShortcut(action: action, chord: chord, occupant: occupant, warning: warning)
            } else {
                store.assign(chord, to: action)
                stopRecording()
            }
        }
    }
}
#endif
