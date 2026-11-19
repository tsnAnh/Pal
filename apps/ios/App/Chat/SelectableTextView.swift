#if os(iOS)
import SwiftUI
import UIKit

struct SelectableTextView: UIViewRepresentable {
    let text: String
    let maxHeight: CGFloat

    final class Coordinator {
        var didSelectAll = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.accessibilityIdentifier = "selectableMessageText"
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        guard !context.coordinator.didSelectAll, !text.isEmpty else { return }
        context.coordinator.didSelectAll = true
        Task {
            view.becomeFirstResponder()
            view.selectAll(nil)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(max(fitted.height, 44), maxHeight))
    }
}
#endif
