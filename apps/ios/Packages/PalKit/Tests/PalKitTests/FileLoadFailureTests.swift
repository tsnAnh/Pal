import Foundation
import PalChat
import PalProtocol
import PalTransport
import Testing

@Suite("Failed file loads")
struct FileLoadFailureTests {
    private func failure(_ code: Int) -> FileLoadFailure {
        FileLoadFailure(describing: RPCError(code: code, message: "x"))
    }

    @Test("each gateway code maps to its own plain reason")
    func gatewayCodes() {
        #expect(failure(4151).reason == "Not found on the bot's computer")
        #expect(failure(4154).reason == "Not allowed to share this file")
        #expect(failure(4152).reason == "Too large to download (limit 16 MB)")
        #expect(failure(5151).reason == "The bot couldn't load this file right now")
        #expect(FileLoadFailure(describing: GatewayTransportError.rpc(RPCError(code: 4154, message: "x"))).cause == .notAllowed)
    }

    @Test("the size limit shown is the one the request used")
    func limitIsReported() {
        let error = RPCError(code: 4152, message: "x")
        #expect(FileLoadFailure(describing: error, limitBytes: 8_000_000).reason == "Too large to download (limit 8 MB)")
    }

    @Test("transport problems say the bot is unreachable")
    func transport() {
        let unreachable = [
            FileLoadFailure(describing: ChatError.notConnected),
            FileLoadFailure(describing: URLError(.notConnectedToInternet)),
            FileLoadFailure(describing: GatewayTransportError.timedOut),
            FileLoadFailure(describing: GatewayTransportError.closed(.normal)),
        ]
        #expect(unreachable.allSatisfy { $0.cause == .unreachable && $0.reason == "Can't reach the bot right now" })
    }

    @Test("only a truly unknown error gets the generic text, and an RPC one carries its code")
    func unknown() {
        let rpc = failure(4153)
        #expect(rpc.reason == "The bot could not provide it right now.")
        #expect(rpc.message == "The bot could not provide it right now. · Error 4153")
        let other = FileLoadFailure(describing: ChatError.attachmentRefused)
        #expect(other.reason == "The bot could not provide it right now.")
        #expect(other.message == other.reason)
    }

    @Test("a failure that is already a file failure is kept as it is")
    func passthrough() {
        let original = FileLoadFailure(cause: .notAllowed)
        #expect(FileLoadFailure(describing: original) == original)
    }

    @Test("the card offers Retry only for failures that can pass on their own")
    func retryOnlyForTransient() {
        let causes: [(FileLoadFailure.Cause, Bool)] = [
            (.notFound, false),
            (.notAllowed, false),
            (.tooLarge(limitMegabytes: 16), false),
            (.unreachable, true),
            (.internalFailure, true),
            (.unknown(code: 4153), true),
        ]
        for (cause, retry) in causes {
            #expect(FileCardPhase.failed(FileLoadFailure(cause: cause)).offersRetry == retry)
        }
        #expect(!FileCardPhase.checking.offersRetry)
        #expect(!FileCardPhase.ready.offersRetry)
    }
}
