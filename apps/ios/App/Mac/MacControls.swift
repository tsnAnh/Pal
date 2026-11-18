#if os(macOS)
import PalDesign
import SwiftUI

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
