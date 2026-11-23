import SwiftUI

public struct PalTextField: View {
    @Binding private var text: String
    private let label: Text
    private let prompt: Text?
    private let axis: Axis?
    private let isSecure: Bool

    public init(_ label: LocalizedStringKey, text: Binding<String>, prompt: Text? = nil, axis: Axis? = nil, isSecure: Bool = false) {
        self.init(label: Text(label), text: text, prompt: prompt, axis: axis, isSecure: isSecure)
    }

    public init<S: StringProtocol>(_ label: S, text: Binding<String>, prompt: Text? = nil, axis: Axis? = nil, isSecure: Bool = false) {
        self.init(label: Text(label), text: text, prompt: prompt, axis: axis, isSecure: isSecure)
    }

    fileprivate init(label: Text, text: Binding<String>, prompt: Text?, axis: Axis? = nil, isSecure: Bool) {
        _text = text
        self.label = label
        self.prompt = prompt
        self.axis = axis
        self.isSecure = isSecure
    }

    public var body: some View {
        field
            .textFieldStyle(.plain)
            .focusEffectDisabled()
    }

    @ViewBuilder
    private var field: some View {
        let promptText = (prompt ?? label).foregroundStyle(PalTokens.textTertiary)
        if isSecure {
            SecureField(text: $text, prompt: promptText) { label }
        } else if let axis {
            TextField(text: $text, prompt: promptText, axis: axis) { label }
        } else {
            TextField(text: $text, prompt: promptText) { label }
        }
    }
}

public struct PalTextEditor: View {
    @Binding private var text: String

    public init(text: Binding<String>) {
        _text = text
    }

    public var body: some View {
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .focusEffectDisabled()
    }
}

public struct PalGlassTextField: View {
    @Binding private var text: String
    private let label: Text
    private let prompt: Text?
    private let icon: String?
    private let isSecure: Bool
    private let identifier: String?
    private let minHeight: CGFloat

    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 14
    @FocusState private var isFocused: Bool

    public init(
        _ label: LocalizedStringKey, text: Binding<String>, prompt: Text? = nil, icon: String? = nil,
        isSecure: Bool = false, identifier: String? = nil, minHeight: CGFloat = 38, fontSize: CGFloat = 14
    ) {
        self.init(
            label: Text(label), text: text, prompt: prompt, icon: icon, isSecure: isSecure,
            identifier: identifier, minHeight: minHeight, fontSize: fontSize
        )
    }

    public init<S: StringProtocol>(
        _ label: S, text: Binding<String>, prompt: Text? = nil, icon: String? = nil,
        isSecure: Bool = false, identifier: String? = nil, minHeight: CGFloat = 38, fontSize: CGFloat = 14
    ) {
        self.init(
            label: Text(label), text: text, prompt: prompt, icon: icon, isSecure: isSecure,
            identifier: identifier, minHeight: minHeight, fontSize: fontSize
        )
    }

    private init(
        label: Text, text: Binding<String>, prompt: Text?, icon: String?,
        isSecure: Bool, identifier: String?, minHeight: CGFloat, fontSize: CGFloat
    ) {
        _text = text
        self.label = label
        self.prompt = prompt
        self.icon = icon
        self.isSecure = isSecure
        self.identifier = identifier
        self.minHeight = minHeight
        _fontSize = ScaledMetric(wrappedValue: fontSize, relativeTo: .body)
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let icon {
                PalIcon(icon, ink: .secondary)
                    .font(.system(size: fontSize))
                    .accessibilityHidden(true)
            }
            input
        }
        .padding(.horizontal, 14)
        .frame(minHeight: minHeight)
        .palClearGlass(Capsule(), interactive: isFocused)
    }

    private var input: some View {
        PalTextField(label: label, text: $text, prompt: prompt, isSecure: isSecure)
            .font(.system(size: fontSize))
            .foregroundStyle(PalTokens.textPrimary)
            .autocorrectionDisabled()
            .focused($isFocused)
            .palIdentified(identifier)
    }
}

private extension View {
    @ViewBuilder
    func palIdentified(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
