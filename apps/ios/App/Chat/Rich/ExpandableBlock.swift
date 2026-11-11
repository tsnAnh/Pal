import PalDesign
import SwiftUI

struct ExpandableBlock<Content: View>: View {
    let lineCount: Int
    let content: Content

    init(lineCount: Int, @ViewBuilder content: () -> Content) {
        self.lineCount = lineCount
        self.content = content()
    }

    @State private var expanded = false
    @ScaledMetric(relativeTo: .footnote) private var lineHeight: CGFloat = 17

    private var collapsible: Bool { lineCount > RichCode.collapseLines }
    private var clipped: Bool { collapsible && !expanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                content
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
            .frame(maxHeight: clipped ? lineHeight * CGFloat(RichCode.collapseLines) + 20 : nil)
            .mask {
                if clipped {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 28)
                    }
                } else {
                    Rectangle()
                }
            }
            if collapsible {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PalTokens.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: Self.hitHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(expanded ? LocalizedStringKey("Collapse") : LocalizedStringKey("Expand")))
                .accessibilityIdentifier("expandableToggle")
            }
        }
    }

    private static var hitHeight: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }
}
