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
    private var estimated: Set<String> = []
    private var ids: [String] = []
    private var rows: [ChatRow] = []
    private(set) var plan = ChatTailPlan(start: 0, hiddenHeight: 0)
    private var narrowed: ChatTailPlan?
    private var drift = 0.0
    static let resizeMinimumRows = 3
    nonisolated static let anchorTolerance = 0.5

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
        narrowed = nil
        let known = persisted.map { file in (file, width.map { abs($0 - file.width) <= 0.5 } ?? true) }
        let records = known.flatMap { $0.1 ? $0.0.records(width: $0.0.width, textScale: $0.0.textScale) : nil } ?? [:]
        let layoutWidth = width ?? persisted?.width ?? Self.fallbackWidth
        for row in rows where planned[row.id] == nil || estimated.contains(row.id) {
            let shape = row.heightShape
            shapes[row.id] = shape
            if let height = measured(row.id, layoutWidth) {
                planned[row.id] = height
                estimated.remove(row.id)
            } else if let record = records[row.id], record.hash == row.heightFingerprint {
                planned[row.id] = record.height
                estimated.remove(row.id)
                seed(row, record.height, persisted?.width ?? layoutWidth)
            } else {
                planned[row.id] = estimator.estimate(shape, width: layoutWidth, lineHeight: lineHeight)
                estimated.insert(row.id)
            }
        }
        let height = { [planned] (id: String) in planned[id] ?? 0 }
        plan = tail.plan(ids: ids, viewport: context.viewport ?? persisted?.viewport, height: height)
        plan.hiddenHeight = anchored(plan)
        return plan
    }

    func resumeOpen() {
        tail.reset()
        rows = []
        ids = []
        narrowed = nil
        drift = 0
        plan = ChatTailPlan(start: 0, hiddenHeight: 0)
    }

    func resizingPlan(viewport: Double?) -> ChatTailPlan {
        if let narrowed { return narrowed }
        guard let viewport, plan.start < ids.count else { return plan }
        func height(_ id: String) -> Double { planned[id] ?? 0 }
        var index = ids.count
        var covered = 0.0
        while index > plan.start, covered < viewport || ids.count - index < Self.resizeMinimumRows {
            index -= 1
            covered += height(ids[index])
        }
        guard index > plan.start else { return plan }
        let hidden = plan.hiddenHeight + ids[plan.start..<index].reduce(0) { $0 + height($1) }
        let next = ChatTailPlan(start: index, hiddenHeight: hidden)
        narrowed = next
        return next
    }

    func endResizing() {
        narrowed = nil
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

    func holdDocument(shiftedBy delta: Double) -> Bool {
        guard plan.start > 0, abs(delta) > Self.anchorTolerance else { return false }
        let next = max(plan.hiddenHeight - delta, 0)
        drift += next - plan.hiddenHeight
        plan.hiddenHeight = next
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

    private func replan() {
        let height = { [planned] (id: String) in planned[id] ?? 0 }
        plan = tail.plan(ids: ids, viewport: nil, height: height)
        plan.hiddenHeight = anchored(plan)
    }

    private func anchored(_ plan: ChatTailPlan) -> Double {
        if plan.start == 0 { drift = 0 }
        return max(plan.hiddenHeight + drift, 0)
    }
}
