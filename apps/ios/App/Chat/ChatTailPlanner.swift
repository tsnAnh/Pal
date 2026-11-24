import PalChat
import PalDesign
import SwiftUI

@MainActor
final class ChatTailPlanner {
    static let quiet = Duration.milliseconds(500)
    static let fallbackWidth = 800.0

    private var tail = ChatTail()
    private var estimator = ChatRowHeightEstimator()
    private var planned: [String: Double] = [:]
    private var shapes: [String: ChatRowShape] = [:]
    private var observed: Set<String> = []
    private var ids: [String] = []
    private var rows: [ChatRow] = []
    private(set) var plan = ChatTailPlan(start: 0, hiddenHeight: 0)

    private let lineHeight = Double(ChatLineBox(fontSize: PalTextStyle.chatBody.size).height)

    var hiddenHeight: Double { plan.hiddenHeight }
    var currentRows: [ChatRow] { rows }

    var renderedIDs: [String] { rendered(from: ids) }

    func rendered(from ids: [String]) -> [String] {
        Array(ids[tail.start(in: ids)...])
    }

    func renderedRows(of rows: [ChatRow]) -> ArraySlice<ChatRow> {
        rows[min(plan.start, rows.count)...]
    }

    struct Context {
        var persisted: ChatRowHeightFile?
        var viewport: Double?
        var width: Double?
    }

    func resolve(
        rows: [ChatRow], context: Context, measured: (String, Double) -> Double?, seed: (ChatRow, Double, Double) -> Void
    ) -> ChatTailPlan {
        let persisted = context.persisted
        let width = context.width
        if rows.count == self.rows.count, rows.first?.id == self.rows.first?.id, rows.last?.id == self.rows.last?.id { return plan }
        self.rows = rows
        ids = rows.map(\.id)
        let known = persisted.map { file in (file, width.map { abs($0 - file.width) <= 0.5 } ?? true) }
        let records = known.flatMap { $0.1 ? $0.0.records(width: $0.0.width, textScale: $0.0.textScale) : nil } ?? [:]
        let layoutWidth = width ?? persisted?.width ?? Self.fallbackWidth
        for row in rows where planned[row.id] == nil {
            let shape = row.heightShape
            shapes[row.id] = shape
            if let height = measured(row.id, layoutWidth) {
                planned[row.id] = height
            } else if let record = records[row.id], record.hash == row.heightFingerprint {
                planned[row.id] = record.height
                seed(row, record.height, persisted?.width ?? layoutWidth)
            } else {
                planned[row.id] = estimator.estimate(shape, width: layoutWidth, lineHeight: lineHeight)
            }
        }
        let height = { [planned] (id: String) in planned[id] ?? 0 }
        plan = tail.plan(ids: ids, viewport: context.viewport ?? persisted?.viewport, height: height)
        return plan
    }

    func extend(deficit: Double) -> Bool {
        let height = { [planned] (id: String) in planned[id] ?? 0 }
        guard tail.extend(ids: ids, deficit: deficit, height: height) else { return false }
        replan()
        return true
    }

    func reveal(_ id: String) -> Bool {
        guard tail.reveal(id, in: ids) else { return false }
        replan()
        return true
    }

    func observe(_ id: String, height: Double, width: Double) {
        guard observed.insert(id).inserted, let shape = shapes[id] else { return }
        estimator.observe(shape, measured: height, width: width, lineHeight: lineHeight)
    }

    func file(width: Double, textScale: String, viewport: Double?, measured: (String) -> Double?) -> ChatRowHeightFile {
        var records: [ChatRowHeightRecord] = []
        for row in rows {
            guard let hash = row.heightFingerprint, let height = measured(row.id) else { continue }
            records.append(ChatRowHeightRecord(id: row.id, hash: hash, height: height))
        }
        return ChatRowHeightFile(width: width, textScale: textScale, viewport: viewport, rows: records)
    }

    func widthChanged() {
        planned.removeAll(keepingCapacity: true)
        rows = []
    }

    private func replan() {
        let height = { [planned] (id: String) in planned[id] ?? 0 }
        plan = tail.plan(ids: ids, viewport: nil, height: height)
    }
}
