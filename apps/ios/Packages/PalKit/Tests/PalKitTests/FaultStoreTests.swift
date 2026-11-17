import Foundation
import PalClient
import PalProtocol
import PalTransport
import Synchronization
import Testing

private final class FakeNow: Sendable {
    let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: @Sendable () -> Date { { self.value.withLock { $0 } } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

private final class Sent: Sendable {
    let reports = Mutex<[JSONValue]>([])
}

private func scratchFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("faults-\(UUID().uuidString).json")
}

private func transport(_ method: String = "chat.provider.list", reason: String = "offline") -> GatewayFault {
    .transport(reason, method: method)
}

private let refusal = GatewayFault(code: 4403, reason: "owner_only", trace: TraceID("7f3k2m9a")!, method: "chat.provider.list",
                                   source: .gateway, gatewayVersion: "291aaa2b")

struct FaultStoreTests {
    @Test func keepsOnlyTheNewestTwoHundred() async {
        let clock = FakeNow()
        let store = FaultStore(fileURL: scratchFile(), now: clock.now)
        for index in 0..<205 {
            await store.record(transport("m\(index)"))
            clock.advance(1)
        }
        let records = await store.records()
        #expect(records.count == 200)
        #expect(records.first?.method == "m204")
        #expect(records.last?.method == "m5")
    }

    @Test func survivesARelaunch() async {
        let file = scratchFile()
        let clock = FakeNow()
        await FaultStore(fileURL: file, now: clock.now).record(refusal)
        let reloaded = await FaultStore(fileURL: file, now: clock.now).records()
        #expect(reloaded.map(\.trace) == ["7f3k2m9a"])
        #expect(reloaded.first?.gatewayVersion == "291aaa2b")
    }

    @Test func dropsFaultsOlderThanSevenDays() async {
        let clock = FakeNow()
        let store = FaultStore(fileURL: scratchFile(), now: clock.now)
        await store.record(transport("old"))
        clock.advance(6 * 24 * 3600)
        await store.record(transport("recent"))
        clock.advance(24 * 3600 + 1)
        #expect(await store.records().map(\.method) == ["recent"])
    }

    @Test func clearEmptiesTheStoreOnDisk() async {
        let file = scratchFile()
        let store = FaultStore(fileURL: file)
        await store.record(refusal)
        await store.clear()
        #expect(await store.records().isEmpty)
        #expect(await FaultStore(fileURL: file).records().isEmpty)
    }

    @Test func copyTextMatchesTheStatusDetailsLine() {
        let record = FaultRecord(refusal, at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(record.copyText(appVersion: "1.4 88") == "\(refusal.detailsLine)\napp: 1.4 88")
        let line = FaultRecord.lines([record], appVersion: "1.4 88")
        #expect(line.contains("owner_only") && line.contains("code 4403") && line.contains("chat.provider.list"))
        #expect(line.contains("trace 7f3k2m9a") && line.contains("gateway 291aaa2b") && line.contains("app 1.4 88"))
    }

    @Test func noParamValueOrTokenReachesTheStoreOrTheCopyText() async throws {
        let file = scratchFile()
        let gateway = try await FakeGateway.start { _, _, _ in
            .failure(RPCError(code: 4403, message: "fake-token-do-not-use", data: ["reason": "owner_only"]))
        }
        let store = FaultStore(fileURL: file)
        let connection = try await GatewayConnection.dial(url: gateway.url, ticket: "t", options: GatewayDialOptions(faults: store))
        _ = try? await connection.call("chat.provider.list", params: ["token": "fake-token-do-not-use"])
        await connection.close()
        let records = await store.records()
        #expect(records.count == 1)
        let disk = try #require(String(bytes: try Data(contentsOf: file), encoding: .utf8))
        #expect(!disk.contains("fake-token-do-not-use"))
        #expect(!FaultRecord.lines(records, appVersion: "1").contains("fake-token-do-not-use"))
        #expect(!(records.first?.copyText(appVersion: "1").contains("fake-token-do-not-use") ?? true))
    }
}

struct FaultReporterTests {
    private final class Gateway: Sendable {
        let reports = Mutex<[JSONValue]>([])
        let failing = Mutex(false)

        var call: FaultReporter.Call {
            { method, params in
                #expect(method == "diag.report")
                if self.failing.withLock({ $0 }) { throw GatewayTransportError.timedOut }
                self.reports.withLock { $0.append(params) }
                return ["recorded": true]
            }
        }
    }

    @Test func reportsOnlyTransportAndDecodeFaultsOnceEachOldestFirst() async {
        let clock = FakeNow()
        let store = FaultStore(fileURL: scratchFile(), now: clock.now)
        await store.record(transport("first", reason: "timeout"))
        clock.advance(1)
        await store.record(refusal)
        clock.advance(1)
        await store.record(.decode(method: "second"))
        let gateway = Gateway()
        await FaultReporter.flush(store, call: gateway.call)
        await FaultReporter.flush(store, call: gateway.call)
        let reports = gateway.reports.withLock { $0 }
        #expect(reports.map { $0["method"]?.stringValue } == ["first", "second"])
        #expect(reports.map { $0["source"]?.stringValue } == ["transport", "decode"])
        #expect(reports.first?["reason"]?.stringValue == "timeout")
        #expect(await store.records().filter(\.reported).map(\.method) == ["second", "first"])
    }

    @Test func sendsAtMostTwentyPerReconnect() async {
        let store = FaultStore(fileURL: scratchFile())
        for index in 0..<25 { await store.record(transport("m\(index)")) }
        let gateway = Gateway()
        await FaultReporter.flush(store, call: gateway.call)
        #expect(gateway.reports.withLock { $0.count } == 20)
        await FaultReporter.flush(store, call: gateway.call)
        #expect(gateway.reports.withLock { $0.count } == 25)
    }

    @Test func aFailedReportIsRetriedOnTheNextReconnect() async {
        let store = FaultStore(fileURL: scratchFile())
        await store.record(transport())
        let gateway = Gateway()
        gateway.failing.withLock { $0 = true }
        await FaultReporter.flush(store, call: gateway.call)
        #expect(await store.records().first?.reported == false)
        gateway.failing.withLock { $0 = false }
        await FaultReporter.flush(store, call: gateway.call)
        #expect(gateway.reports.withLock { $0.count } == 1)
        #expect(await store.records().first?.reported == true)
    }

    @Test func aTimedOutCallIsReportedToTheFakeGatewayAfterReconnect() async throws {
        let box = Sent()
        let gateway = try await FakeGateway.start { method, params, _ in
            if method == "diag.report" {
                box.reports.withLock { $0.append(params ?? .null) }
                return .result(["recorded": true])
            }
            return .silence
        }
        let store = FaultStore(fileURL: scratchFile())
        let options = GatewayDialOptions(faults: store)
        let first = try await GatewayConnection.dial(url: gateway.url, ticket: "t", options: options)
        _ = try? await first.call("chat.provider.list", timeout: .milliseconds(100))
        await first.close()
        let trace = try #require(await store.records().first?.trace)
        let second = try await GatewayConnection.dial(url: gateway.url, ticket: "t", options: options)
        await FaultReporter.flush(store) { try await second.call($0, params: $1, timeout: .seconds(5)) }
        await second.close()
        let sent = box.reports.withLock { $0 }
        #expect(sent.count == 1)
        #expect(sent.first?["trace"]?.stringValue == trace)
        #expect(sent.first?["reason"]?.stringValue == "timeout")
        #expect(sent.first?["source"]?.stringValue == "transport")
        #expect(await store.records().first?.reported == true)
    }
}
