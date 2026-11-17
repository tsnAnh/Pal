import Foundation
import PalConnect
import PalDevice
import PalDiagnostics
import PalProtocol
import PalTransport
import Synchronization
import Testing

@Suite("Google sign-in flow")
struct GoogleSignInFlowTests {
    private func gateway(finish: [JSONValue]) -> CustomRPC {
        let queue = ReplyQueue(finish)
        return CustomRPC([
            "google_workspace.signin.start": googleReply(startReply()),
            "google_workspace.signin.finish": { _ in queue.next() },
            "google_workspace.signin.cancel": googleReply(.object(["ok": true])),
            "google_workspace.status": googleReply(googleSignedInStatus),
        ])
    }

    @Test func startSendsTheTickedServices() async throws {
        let rpc = gateway(finish: [])
        var selection = GoogleScopeSelection()
        selection.setRead(.contacts, false)
        selection.setWrite(.gmail, true)
        let session = try await googleService(rpc).beginSignIn(selection)
        #expect(session.authURL.absoluteString == googleAuthLink)
        let params = try #require(rpc.params("google_workspace.signin.start").first)
        #expect(params["services"]?.arrayValue?.count == 5)
        #expect(params["write_services"] == .array([.string("gmail")]))
        #expect(params["profile"] == nil)
    }

    @Test func anEmptySelectionNeverCallsTheGateway() async {
        let rpc = gateway(finish: [])
        var selection = GoogleScopeSelection()
        for service in GoogleService.allCases { selection.setRead(service, false) }
        await #expect(throws: GoogleWorkspaceError.invalidServices) { try await googleService(rpc).beginSignIn(selection) }
        #expect(rpc.methods().isEmpty)
    }

    @Test func refusesLinksThatAreNotHttpsGoogle() async {
        let urls = [
            "http://accounts.google.com/o/oauth2/v2/auth", "https://evil.example.com/o/oauth2/v2/auth", "https://google.com.evil.example/auth",
            "https://accounts.google.com@evil.example/auth", "javascript:alert(1)",
        ]
        for url in urls {
            let rpc = CustomRPC([
                "google_workspace.signin.start": googleReply(startReply(url: url)),
                "google_workspace.signin.cancel": googleReply(.object(["ok": true])),
            ])
            await #expect(throws: GoogleWorkspaceError.failed) { try await googleStarted(rpc) }
            #expect(rpc.methods() == ["google_workspace.signin.start", "google_workspace.signin.cancel"])
        }
    }

    @Test func aMissingFlowIDIsAFailure() async {
        let rpc = CustomRPC(["google_workspace.signin.start": googleReply(.object(["auth_url": .string(googleAuthLink)]))])
        await #expect(throws: GoogleWorkspaceError.failed) { try await googleStarted(rpc) }
    }

    @Test func retryKeepsTheFlowOpenAndSignedInClosesIt() async throws {
        let rpc = gateway(finish: [
            finishReply("retry", code: "bad_paste", message: "Paste the whole address."),
            finishReply("signed_in", status: googleSignedInStatus),
        ])
        let session = try await googleStarted(rpc)
        #expect(await session.submit("first") == .tryAgain("Paste the whole address."))
        guard case .signedIn(let status) = await session.submit("second") else {
            Issue.record("expected signed in")
            return
        }
        #expect(status.email == "owner@example.com")
        #expect(status.writeServices == [.drive])
        let calls = rpc.methods().count
        guard case .failed = await session.submit("third") else {
            Issue.record("a closed flow must refuse")
            return
        }
        #expect(rpc.methods().count == calls)
        await session.cancel()
        #expect(rpc.methods().count == calls)
        #expect(rpc.methods().filter { $0 == "google_workspace.signin.finish" }.count == 2)
    }

    @Test func eachSubmitSendsThePasteOnceWithTheFlow() async throws {
        let rpc = gateway(finish: [finishReply("retry"), finishReply("denied", code: "denied", message: "Access was declined.")])
        let session = try await googleStarted(rpc)
        _ = await session.submit("http://127.0.0.1:1/?code=A")
        _ = await session.submit("http://127.0.0.1:1/?code=B")
        let sent = rpc.params("google_workspace.signin.finish")
        #expect(sent.map { $0["flow_id"]?.stringValue } == ["flow-1", "flow-1"])
        #expect(sent.map { $0["pasted"]?.stringValue } == ["http://127.0.0.1:1/?code=A", "http://127.0.0.1:1/?code=B"])
    }

    @Test func deniedAndFailedCloseTheFlow() async throws {
        let denied = gateway(finish: [finishReply("denied", code: "denied", message: "Access was declined.")])
        let deniedSession = try await googleStarted(denied)
        #expect(await deniedSession.submit("x") == .denied("Access was declined."))
        guard case .failed = await deniedSession.submit("y") else {
            Issue.record("denied flow must be closed")
            return
        }
        #expect(denied.params("google_workspace.signin.finish").count == 1)

        let failed = gateway(finish: [finishReply("failed", code: "expired")])
        let failedSession = try await googleStarted(failed)
        guard case .failed(let reason) = await failedSession.submit("x") else {
            Issue.record("expected failure")
            return
        }
        #expect(reason == GoogleWorkspaceError.failed.reason)
        #expect(failed.params("google_workspace.signin.finish").count == 1)
    }

    @Test func signedInWithoutAnEmbeddedStatusReadsIt() async throws {
        let rpc = gateway(finish: [finishReply("signed_in")])
        let session = try await googleStarted(rpc)
        guard case .signedIn(let status) = await session.submit("x") else {
            Issue.record("expected signed in")
            return
        }
        #expect(status.state == .signedIn)
        #expect(rpc.methods().last == "google_workspace.status")
    }

    @Test func aTransportFailureClosesTheFlowAndCancelsIt() async throws {
        let rpc = CustomRPC([
            "google_workspace.signin.start": googleReply(startReply()),
            "google_workspace.signin.finish": gatewayError(5321, "unreachable"),
            "google_workspace.signin.cancel": googleReply(.object(["ok": true])),
        ])
        let session = try await googleStarted(rpc)
        #expect(await session.submit("x") == .failed(GoogleWorkspaceError.unreachable.reason))
        #expect(rpc.methods().filter { $0 == "google_workspace.signin.cancel" }.count == 1)
        _ = await session.submit("again")
        #expect(rpc.methods().filter { $0 == "google_workspace.signin.finish" }.count == 1)
    }

    @Test func cancelIsIdempotentAndCallsTheGatewayOnce() async throws {
        let rpc = gateway(finish: [])
        let session = try await googleStarted(rpc)
        await session.cancel()
        await session.cancel()
        #expect(rpc.methods().filter { $0 == "google_workspace.signin.cancel" }.count == 1)
        #expect(rpc.params("google_workspace.signin.cancel") == [.object(["flow_id": "flow-1"])])
        guard case .failed = await session.submit("x") else {
            Issue.record("a cancelled flow must refuse")
            return
        }
        #expect(rpc.methods().filter { $0 == "google_workspace.signin.finish" }.isEmpty)
    }

    @Test func aSecondSubmitWhileOneIsRunningIsRefused() async throws {
        let inner = gateway(finish: [finishReply("signed_in", status: googleSignedInStatus)])
        let session = try await googleStarted(SlowFinish(inner: inner))
        let first = Task { await session.submit("slow") }
        try await Task.sleep(for: .milliseconds(50))
        guard case .failed = await session.submit("fast") else {
            Issue.record("single flight")
            return
        }
        guard case .signedIn = await first.value else {
            Issue.record("the first submit must finish")
            return
        }
        #expect(inner.params("google_workspace.signin.finish").count == 1)
    }
}

private struct SlowFinish: ConnectRPC {
    let inner: CustomRPC

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        if method == "google_workspace.signin.finish" { try await Task.sleep(for: .milliseconds(250)) }
        return try await inner.call(method, params)
    }
}
