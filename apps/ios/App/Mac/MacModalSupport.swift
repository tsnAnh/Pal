#if os(macOS)
import HermesDesign
import SwiftUI

struct MacModalScrim: View {
    let dismiss: () -> Void

    var body: some View {
        PalTokens.scrim
            .contentShape(Rectangle())
            .onTapGesture(perform: dismiss)
            .accessibilityHidden(true)
            .transition(.opacity)
    }
}

struct MacPanelCloseIdentifierKey: PreferenceKey {
    static let defaultValue: String? = nil

    static func reduce(value: inout String?, nextValue: () -> String?) {
        value = nextValue() ?? value
    }
}

struct MacModalPanel<Content: View>: View {
    let width: CGFloat
    var height: CGFloat?
    var background = PalTokens.elevated
    let identifier: String
    let closeIdentifier: String
    let close: () -> Void
    @ViewBuilder let content: Content

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        content
            .frame(width: width, height: height)
            .background(background, in: shape)
            .overlay(shape.strokeBorder(PalTokens.panelBorder, lineWidth: 1))
            .overlayPreferenceValue(MacPanelCloseIdentifierKey.self, alignment: .topTrailing) { override in
                MacPlainCloseButton(identifier: override ?? closeIdentifier, action: close)
                    .padding(.top, 12)
                    .padding(.trailing, 13)
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.35), radius: 40, y: 18)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
            .transition(.scale(scale: 0.97).combined(with: .opacity))
    }
}

struct MacCaption: View {
    let text: Text

    init(_ text: LocalizedStringKey) { self.text = Text(text) }
    init(verbatim text: String) { self.text = Text(verbatim: text) }

    var body: some View {
        text
            .font(.system(size: 11))
            .foregroundStyle(PalTokens.textSecondary)
            .padding(.leading, 13)
            .padding(.bottom, 8)
    }
}

struct MacFootnote: View {
    let text: String
    var identifier: String?

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(PalTokens.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 13)
            .padding(.top, 8)
            .accessibilityIdentifier(identifier ?? "macFootnote")
    }
}

struct MacCard<Content: View>: View {
    var identifier: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PalTokens.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier ?? "macCard")
    }
}

struct MacRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var identifier: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(PalTokens.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

struct MacMenuValue<Value: Hashable, Options: View>: View {
    let current: String
    @Binding var selection: Value
    let identifier: String
    @ViewBuilder let options: Options

    var body: some View {
        Menu {
            Picker(current, selection: $selection) { options }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            MacValueLabel(text: current)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier(identifier)
    }
}

struct MacValueLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(PalTokens.textSecondary)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(PalTokens.textPrimary)
        .padding(.horizontal, 12)
        .frame(height: 27)
        .overlay(Capsule().strokeBorder(PalTokens.hairline, lineWidth: 1))
        .contentShape(Capsule())
    }
}
#endif
