import Foundation
import PalDevice
import PalProtocol
import Synchronization
import Testing

private final class FakePasteboard: PasteboardStore {
    private struct State {
        var types: [String]
        var text: String?
        var image: ClipboardImage?
        var replaced: [String] = []
        var imageWrites: [(Data, String)] = []
    }

    private let state: Mutex<State>
    let accessAllowed: Bool
    let accepts: Bool

    init(types: [String], text: String? = nil, image: ClipboardImage? = nil, accessAllowed: Bool = true, accepts: Bool = true) {
        state = Mutex(State(types: types, text: text, image: image))
        self.accessAllowed = accessAllowed
        self.accepts = accepts
    }

    var replacedTexts: [String] { state.withLock { $0.replaced } }
    var imageWrites: [(Data, String)] { state.withLock { $0.imageWrites } }

    func types() -> [String] { state.withLock { $0.types } }
    func text() -> String? { state.withLock { $0.text } }
    func image() -> ClipboardImage? { state.withLock { $0.image } }

    func replace(text: String) -> Bool {
        guard accepts else { return false }
        state.withLock { $0.replaced.append(text) }
        return true
    }

    func replace(image: Data, type: String) -> Bool {
        guard accepts else { return false }
        state.withLock { $0.imageWrites.append((image, type)) }
        return true
    }
}

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
private let textType = "public.utf8-plain-text"

private func clipboardRequest(_ action: String, args: JSONValue = [:]) -> DeviceToolRequest {
    DeviceToolRequest(
        requestID: "req-00000001", action: action, connector: DeviceToolAction(rawValue: action)?.connector.rawValue ?? "",
        args: args, deadlineSeconds: 30
    )
}

private func executor(_ board: FakePasteboard, state: DeviceConnectorState = .allowed) async -> DeviceToolExecutor {
    let ledger = ConnectorLedger(api: FakeConnectorsAPI([.clipboard: state]))
    _ = try? await ledger.refresh()
    return DeviceToolExecutor(
        providers: DeviceProviders(clipboard: SystemClipboard(store: board)),
        permissions: FakePermissions(), ledger: ledger, consent: FakeConsent(),
        environment: DeviceToolEnvironment(deadlineMargin: .zero)
    )
}

private func success(_ outcome: DeviceToolOutcome) -> JSONValue? {
    if case .success(let value) = outcome { return value }
    return nil
}

private func failure(_ outcome: DeviceToolOutcome) -> DeviceToolErrorCode? {
    if case .failure(let code, _) = outcome { return code }
    return nil
}

@Suite struct DeviceClipboardTests {
    @Test func textIsReadAndOtherKindsAreReported() async throws {
        let board = FakePasteboard(types: [textType, "public.png", "public.file-url"], text: "hello")
        let value = try #require(success(await executor(board).execute(clipboardRequest("clipboard.read"))))
        #expect(value["text"]?.stringValue == "hello")
        #expect(value["types"] == ["text", "image", "file_urls"])
        #expect(value["concealed"]?.boolValue == false && value["truncated"]?.boolValue == false)
        #expect(value["image_base64"] == nil)
    }

    @Test func aLongClipboardIsCutAndFlagged() async throws {
        let board = FakePasteboard(types: [textType], text: String(repeating: "é", count: 40_000))
        let value = try #require(success(await executor(board).execute(clipboardRequest("clipboard.read"))))
        #expect(value["truncated"]?.boolValue == true)
        #expect((value["text"]?.stringValue?.utf8.count ?? .max) <= DeviceTextLimit.clipboardText + 64)
    }

    @Test func concealedAndTransientItemsAreNotReadable() async throws {
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
            let board = FakePasteboard(types: [textType, marker], text: "hunter2")
            let value = try #require(success(await executor(board).execute(clipboardRequest("clipboard.read", args: ["include_image": true]))))
            #expect(value["concealed"]?.boolValue == true)
            #expect(value["text"] == nil && value["image_base64"] == nil)
        }
    }

    @Test func anImageIsReturnedOnlyWhenAskedAndSmallEnough() async throws {
        let board = FakePasteboard(types: ["public.png"], image: ClipboardImage(data: png, mime: "image/png"))
        let plain = try #require(success(await executor(board).execute(clipboardRequest("clipboard.read"))))
        #expect(plain["image_base64"] == nil && plain["image_bytes"] == nil)
        let asked = try #require(success(await executor(board).execute(clipboardRequest("clipboard.read", args: ["include_image": true]))))
        #expect(asked["image_base64"]?.stringValue == png.base64EncodedString() && asked["image_mime"]?.stringValue == "image/png")
        let huge = FakePasteboard(types: ["public.png"], image: ClipboardImage(data: Data(count: DeviceTextLimit.clipboardImage + 1), mime: "image/png"))
        let big = try #require(success(await executor(huge).execute(clipboardRequest("clipboard.read", args: ["include_image": true]))))
        #expect(big["image_base64"] == nil && big["image_bytes"]?.intValue == DeviceTextLimit.clipboardImage + 1)
    }

    @Test func textIsWritten() async throws {
        let board = FakePasteboard(types: [])
        let value = try #require(success(await executor(board).execute(clipboardRequest("clipboard.write", args: ["text": "héllo"]))))
        #expect(board.replacedTexts == ["héllo"])
        #expect(value["kind"]?.stringValue == "text" && value["size"]?.intValue == 5)
    }

    @Test func anImageIsWrittenWithItsRealType() async throws {
        let board = FakePasteboard(types: [])
        _ = try #require(success(await executor(board).execute(clipboardRequest("clipboard.write", args: ["image_base64": .string(png.base64EncodedString())]))))
        #expect(board.imageWrites.map(\.1) == ["public.png"] && board.imageWrites.first?.0 == png)
    }

    @Test func badWritesAreRefusedAndTouchNothing() async {
        let board = FakePasteboard(types: [])
        let run = await executor(board)
        let bad: [JSONValue] = [
            [:], ["text": "a", "image_base64": "AAAA"], ["text": ""], ["image_base64": "not base64!"],
            ["image_base64": .string(Data([1, 2, 3, 4]).base64EncodedString())],
            ["text": .string(String(repeating: "x", count: 100_001))],
        ]
        for args in bad {
            #expect(failure(await run.execute(clipboardRequest("clipboard.write", args: args))) == .invalidArgs)
        }
        #expect(board.replacedTexts.isEmpty && board.imageWrites.isEmpty)
    }

    @Test func aDeniedPasteboardIsReportedAsPermissionDenied() async {
        let board = FakePasteboard(types: [textType], text: "x", accessAllowed: false)
        let run = await executor(board)
        #expect(failure(await run.execute(clipboardRequest("clipboard.read"))) == .permissionDenied)
        #expect(failure(await run.execute(clipboardRequest("clipboard.write", args: ["text": "y"]))) == .permissionDenied)
        #expect(board.replacedTexts.isEmpty)
    }

    @Test func aRefusedWriteFails() async {
        let board = FakePasteboard(types: [], accepts: false)
        #expect(failure(await executor(board).execute(clipboardRequest("clipboard.write", args: ["text": "y"]))) == .failed)
    }

    @Test func aStoredOffIsIgnoredAndAnAppWithoutAProviderIsUnsupported() async {
        let board = FakePasteboard(types: [textType], text: "x")
        let off = await executor(board, state: .off)
        #expect(failure(await off.execute(clipboardRequest("clipboard.read"))) == nil)
        #expect(failure(await off.execute(clipboardRequest("clipboard.write", args: ["text": "y"]))) == nil)
        #expect(board.replacedTexts == ["y"])
        let ledger = ConnectorLedger(api: FakeConnectorsAPI([.clipboard: .allowed]))
        _ = try? await ledger.refresh()
        let bare = DeviceToolExecutor(providers: DeviceProviders(), permissions: FakePermissions(), ledger: ledger, consent: FakeConsent())
        #expect(failure(await bare.execute(clipboardRequest("clipboard.read"))) == .unsupported)
    }

    @Test func theActionsBelongToTheClipboardConnector() {
        #expect([DeviceToolAction.clipboardRead, .clipboardWrite].allSatisfy { $0.connector == .clipboard })
    }
}
