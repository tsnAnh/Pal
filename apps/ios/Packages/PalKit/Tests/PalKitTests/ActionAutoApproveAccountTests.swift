import Foundation
import PalConnect
import PalProtocol
import Synchronization
import Testing

private final class AccountApproveRPC: @unchecked Sendable {
    private let log = Mutex<[(String, JSONValue)]>([])
    private let state = Mutex<[String: Bool]>([:])
    var failing = false

    var calls: [(String, JSONValue)] { log.withLock { $0 } }

    func handle(_ method: String, _ params: JSONValue?) throws -> JSONValue {
        log.withLock { $0.append((method, params ?? .null)) }
        if failing { throw CancellationFailure() }
        let key = (params?["session_id"]?.stringValue ?? "") + "|" + (params?["account"]?.stringValue ?? "")
        if method == "mcp.actions.auto_approve.set" {
            let enabled = params?["enabled"]?.boolValue ?? false
            state.withLock { $0[key] = enabled }
            return ["enabled": .bool(enabled)]
        }
        return ["enabled": .bool(state.withLock { $0[key] ?? false }), "eligible": true]
    }
}

private struct CancellationFailure: Error {}

@MainActor
@Suite("Auto-approve per account")
struct ActionAutoApproveAccountTests {
    private func model(_ rpc: AccountApproveRPC) -> ActionAutoApprove {
        ActionAutoApprove { method, params in try rpc.handle(method, params) }
    }

    @Test func readsAndWritesSendTheAccount() async throws {
        let rpc = AccountApproveRPC()
        let approve = model(rpc)
        await approve.load(sessionID: "s1", account: "work")
        #expect(await approve.setEnabled(true, sessionID: "s1", account: "work"))
        for (_, params) in rpc.calls {
            #expect(params["account"]?.stringValue == "work")
            #expect(params["server"]?.stringValue == "mcp:upwork")
            #expect(params["session_id"]?.stringValue == "s1")
        }
        #expect(rpc.calls.map(\.0) == ["mcp.actions.auto_approve.get", "mcp.actions.auto_approve.set"])
    }

    @Test func enablingOneAccountNeverReadsAsEnabledForAnother() async {
        let rpc = AccountApproveRPC()
        let approve = model(rpc)
        await approve.load(sessionID: "s1", account: "work")
        await approve.load(sessionID: "s1", account: "default")
        _ = await approve.setEnabled(true, sessionID: "s1", account: "work")
        #expect(approve.showsBanner(sessionID: "s1", account: "work"))
        #expect(!approve.showsBanner(sessionID: "s1", account: "default"))
        #expect(approve.entry("s1", account: "default")?.enabled == false)
        #expect(!approve.showsBanner(sessionID: "s1"))
        #expect(approve.entry("s1") == nil)
    }

    @Test func anAccountThatWasNeverLoadedReadsAsNothing() async {
        let approve = model(AccountApproveRPC())
        await approve.load(sessionID: "s1", account: "work")
        _ = await approve.setEnabled(true, sessionID: "s1", account: "work")
        #expect(approve.entry("s1", account: "other") == nil)
        #expect(!approve.showsSwitch(sessionID: "s1", upworkConnected: true, account: "other"))
        #expect(approve.showsSwitch(sessionID: "s1", upworkConnected: true, account: "work"))
    }

    @Test func pendingAndFailureAreKeptPerAccount() async {
        let rpc = AccountApproveRPC()
        let approve = model(rpc)
        await approve.load(sessionID: "s1", account: "work")
        rpc.failing = true
        #expect(!(await approve.setEnabled(true, sessionID: "s1", account: "work")))
        #expect(approve.didFail("s1", account: "work"))
        #expect(!approve.didFail("s1", account: "default"))
        #expect(!approve.didFail("s1"))
        #expect(!approve.isPending("s1", account: "work"))
    }

    @Test func eachSessionKeepsItsOwnAccountEntries() async {
        let approve = model(AccountApproveRPC())
        await approve.load(sessionID: "a", account: "work")
        _ = await approve.setEnabled(true, sessionID: "a", account: "work")
        await approve.load(sessionID: "b", account: "work")
        #expect(approve.showsBanner(sessionID: "a", account: "work"))
        #expect(!approve.showsBanner(sessionID: "b", account: "work"))
    }

    @Test func noAccountKeepsTheUpworkBehaviourAndSendsNoAccount() async throws {
        let rpc = AccountApproveRPC()
        let approve = model(rpc)
        await approve.load(sessionID: "s1")
        #expect(await approve.setEnabled(true, sessionID: "s1"))
        #expect(approve.showsBanner(sessionID: "s1"))
        #expect(approve.showsSwitch(sessionID: "s1", upworkConnected: true))
        for (_, params) in rpc.calls { #expect(params["account"] == nil) }
        #expect(!approve.showsBanner(sessionID: "s1", account: "work"))
    }

    @Test func forgetClearsEveryAccount() async {
        let approve = model(AccountApproveRPC())
        await approve.load(sessionID: "s1", account: "work")
        _ = await approve.setEnabled(true, sessionID: "s1", account: "work")
        approve.forget()
        #expect(!approve.showsBanner(sessionID: "s1", account: "work"))
    }
}
