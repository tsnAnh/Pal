import PalDesign
import SwiftMath
import SwiftUI

struct MathBlockView: View {
    let source: String

    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 20
    @Environment(\.self) private var environment

    var body: some View {
        if Self.parses(source) {
            ScrollView(.horizontal) {
                MathLabel(
                    latex: source,
                    fontSize: fontSize,
                    color: PalTokens.textPrimary.resolve(in: environment).cgColor
                )
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(source)
            .accessibilityAddTraits(.isStaticText)
        } else {
            RichSourceFallback(source: source, note: "Could not draw this formula")
        }
    }

    private static func parses(_ source: String) -> Bool {
        var error: NSError?
        let list = MTMathListBuilder.build(fromString: source, error: &error)
        return list != nil && error == nil
    }
}

struct RichSourceFallback: View {
    let source: String
    let note: String
    var offersCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note)
                .font(.footnote)
                .foregroundStyle(PalTokens.textSecondary)
            ScrollView(.horizontal) {
                Text(source)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(PalTokens.textPrimary)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background(PalTokens.textPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            if offersCopy {
                Button("Copy source") { Pasteboard.string = source }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
    }
}

#if os(iOS)
import UIKit

private struct MathLabel: UIViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let color: CGColor

    func makeUIView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel(frame: .zero)
        label.labelMode = .display
        label.displayErrorInline = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    func updateUIView(_ label: MTMathUILabel, context: Context) {
        if label.fontSize != fontSize { label.fontSize = fontSize }
        label.textColor = UIColor(cgColor: color)
        if label.latex != latex { label.latex = latex }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: MTMathUILabel, context: Context) -> CGSize? {
        label.intrinsicContentSize
    }
}
#elseif os(macOS)
import AppKit

private struct MathLabel: NSViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let color: CGColor

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel(frame: .zero)
        label.labelMode = .display
        label.displayErrorInline = false
        return label
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        if label.fontSize != fontSize { label.fontSize = fontSize }
        label.textColor = NSColor(cgColor: color)
        if label.latex != latex { label.latex = latex }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView label: MTMathUILabel, context: Context) -> CGSize? {
        label.fittingSize
    }
}
#endif
