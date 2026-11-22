@testable import PalChat
import Foundation
import Synchronization
import Testing

private final class ParseLog: Sendable {
    private let sources = Mutex<[String]>([])

    var order: [String] { sources.withLock { $0 } }

    func record(_ source: String) { sources.withLock { $0.append(source) } }
}

private final class Gate: Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func awaitStarted() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.started.wait()
                continuation.resume()
            }
        }
    }
}

private func markdown(_ source: String, log: ParseLog, gate: Gate? = nil) -> DeferredMarkdown {
    DeferredMarkdown(source, parse: { text in
        gate?.started.signal()
        gate?.release.wait()
        log.record(text)
        return MarkdownDocument(parsing: text)
    })
}

private func settle(_ condition: @autoclosure () -> Bool) async {
    for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
}

@Suite struct MarkdownWarmerTests {
    @Test func warmsTheNewestRowsFirstAndEachRowOnce() async {
        let log = ParseLog()
        let gate = Gate()
        let warmer = MarkdownWarmer()
        let rows = [markdown("0", log: log, gate: gate)] + (1...5).map { markdown("\($0)", log: log) }
        warmer.enqueue(rows[0])
        await gate.awaitStarted()
        for row in rows.dropFirst() { warmer.enqueue(row) }
        gate.release.signal()
        await settle(rows.allSatisfy(\.isParsed))
        #expect(log.order == ["0", "5", "4", "3", "2", "1"])
    }

    @Test func warmsEveryPendingRowBeyondTheOldCapacityNewestFirst() async {
        let log = ParseLog()
        let gate = Gate()
        let warmer = MarkdownWarmer()
        let rows = [markdown("0", log: log, gate: gate)] + (1...400).map { markdown("\($0)", log: log) }
        warmer.enqueue(rows[0])
        await gate.awaitStarted()
        for row in rows.dropFirst() { warmer.enqueue(row) }
        gate.release.signal()
        await settle(rows.allSatisfy(\.isParsed))
        let allParsed = rows.allSatisfy(\.isParsed)
        #expect(allParsed)
        #expect(log.order == ["0"] + (1...400).reversed().map(String.init))
    }

    @Test func prioritizedRowsWarmBeforeTheNewestRowsInTheGivenOrder() async {
        let log = ParseLog()
        let gate = Gate()
        let warmer = MarkdownWarmer()
        let rows = [markdown("0", log: log, gate: gate)] + (1...6).map { markdown("\($0)", log: log) }
        warmer.enqueue(rows[0])
        await gate.awaitStarted()
        for row in rows.dropFirst() { warmer.enqueue(row) }
        warmer.prioritize([rows[2], rows[1]])
        warmer.prioritize([rows[2], rows[1]])
        gate.release.signal()
        await settle(rows.allSatisfy(\.isParsed))
        #expect(log.order == ["0", "2", "1", "6", "5", "4", "3"])
    }

    @Test func aReleasedRowDoesNotStallTheQueue() async {
        let log = ParseLog()
        let gate = Gate()
        let warmer = MarkdownWarmer()
        let first = markdown("0", log: log, gate: gate)
        warmer.enqueue(first)
        await gate.awaitStarted()
        warmer.enqueue(markdown("gone", log: log))
        let survivor = markdown("kept", log: log)
        warmer.enqueue(survivor)
        gate.release.signal()
        await settle(survivor.isParsed)
        #expect(survivor.isParsed)
        #expect(first.isParsed)
        #expect(!log.order.contains("gone"))
    }

    @Test func aRowReadWhileItWarmsIsParsedOnceAndMatchesADirectParse() async {
        let log = ParseLog()
        let gate = Gate()
        let warmer = MarkdownWarmer()
        let row = markdown("# title\n\nbody **bold**", log: log, gate: gate)
        warmer.enqueue(row)
        let reader = Task.detached { row.document }
        gate.release.signal()
        let document = await reader.value
        #expect(log.order.count == 1)
        #expect(document == MarkdownDocument(parsing: "# title\n\nbody **bold**"))
        #expect(row.segments == document.messageSegments)
    }
}
