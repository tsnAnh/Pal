import PalChat
import SwiftUI

struct ChatRowMeasureLayer: View {
    let model: ChatModel
    let scroll: ChatScrollController
    let make: (ChatRow, ChatRowContextSource) -> ChatRowView

    var body: some View {
        let batch = scroll.measureBatch(of: model.windowRows)
        if let width = scroll.measureWidth, !batch.isEmpty {
            let source = model.rowContextSource
            VStack(alignment: .leading, spacing: 0) {
                ForEach(batch) { row in
                    make(row, source)
                        .equatable()
                        .chatListRow()
                        .onGeometryChange(for: CGFloat.self) { // perf-lint: ok
                            $0.size.height
                        } action: { height in
                            scroll.measured(row, height: height)
                        }
                }
            }
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: batch.map(\.id)) {
                try? await Task.sleep(for: ChatScrollController.measureTimeout)
                guard !Task.isCancelled else { return }
                scroll.measureGaveUp(on: batch.map(\.id))
            }
        }
    }
}
