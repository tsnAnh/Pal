#if os(macOS)
import PalDesign
import SwiftUI

struct MacPlainCloseButton: View {
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(PalTokens.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help(String(localized: "Close"))
        .accessibilityLabel(Text("Close"))
        .accessibilityIdentifier(identifier)
    }
}

struct MacSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? PalTokens.toggleOn : PalTokens.toggleOff)
                .frame(width: 30, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 16, height: 16).padding(2).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                }
                .animation(.snappy(duration: 0.14), value: configuration.isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

extension ToggleStyle where Self == MacSwitchStyle {
    static var macSwitch: MacSwitchStyle { MacSwitchStyle() }
}
#endif
