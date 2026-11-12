import Foundation
import PalDevice
import PalProtocol
import Synchronization
import Testing
#if os(macOS)
@testable import PalDevice
import SQLite3
#endif

final class FakeMessages: MessagesProviding {
    let calls = Mutex<[String]>([])
    let failure: DeviceProviderError?

    init(failure: DeviceProviderError? = nil) {
        self.failure = failure
    }

    private func record(_ name: String) throws {
        calls.withLock { $0.append(name) }
        if let failure { throw failure }
    }

    func recent(limit: Int, messagesPerChat: Int) async throws -> MessagesRecentRecord {
        try record("recent \(limit) \(messagesPerChat)")
        return MessagesRecentRecord(conversations: [])
    }

    func search(query: String, limit: Int) async throws -> MessagesSearchRecord {
        try record("search \(query) \(limit)")
        return MessagesSearchRecord(matches: [])
    }

    func read(chatID: String, limit: Int) async throws -> MessagesReadRecord {
        try record("read \(chatID) \(limit)")
        return MessagesReadRecord(conversation: ConversationRecord(chatID: chatID, lastAt: Date(timeIntervalSince1970: 0)))
    }

    func send(recipient: String, text: String, service: MessageService?) async throws -> MessageSentRecord {
        try record("send")
        return MessageSentRecord(service: service ?? .imessage, recipient: recipient)
    }

    func access() async -> MessagesAccess { .ready }
}

private func messagesRequest(_ action: String, args: JSONValue = [:]) -> DeviceToolRequest {
    DeviceToolRequest(
        requestID: "req-00000001", action: action, connector: DeviceToolAction(rawValue: action)?.connector.rawValue ?? "",
        args: args, deadlineSeconds: 30
    )
}

private func executor(_ messages: any MessagesProviding, permissions: FakePermissions = FakePermissions()) async -> DeviceToolExecutor {
    let ledger = ConnectorLedger(api: FakeConnectorsAPI([.messages: .allowed]))
    _ = try? await ledger.refresh()
    return DeviceToolExecutor(
        providers: DeviceProviders(messages: messages), permissions: permissions, ledger: ledger, consent: FakeConsent(),
        environment: DeviceToolEnvironment(timeZone: { TimeZone(secondsFromGMT: 0) ?? .current }, deadlineMargin: .zero)
    )
}

private func success(_ outcome: DeviceToolOutcome) -> JSONValue? {
    if case .success(let value) = outcome { return value }
    return nil
}

private func failure(_ outcome: DeviceToolOutcome) -> (DeviceToolErrorCode, String)? {
    if case .failure(let code, let message) = outcome { return (code, message) }
    return nil
}

@Suite struct DeviceMessagesRowTests {
    @Test func theConnectorIsAnOrdinaryMacCatalogEntryAndItsActionsBelongToIt() {
        #expect(DeviceConnectorID.messages.needsOSPermission && !DeviceConnectorID.messages.asksOSPermissionOnUse)
        #expect(DeviceConnectorCatalog.entries(for: .mac).contains { $0.id == .messages && $0.subtitle == "Read and send your messages" })
        #expect(!DeviceConnectorCatalog.entries(for: .ios).contains { $0.id == .messages })
        for name in ["messages.recent", "messages.search", "messages.read", "messages.send"] {
            #expect(DeviceToolAction(rawValue: name)?.connector == .messages)
        }
        #expect(DeviceProviders(messages: FakeMessages()).availableConnectors == [.messages])
    }

    @Test func theRowStatesFollowTheFullDiskAccessPermission() {
        let entry = DeviceConnectorCatalog.entries(for: .mac).first { $0.id == .messages }
        let cases: [(DeviceOSPermission, String?, String)] = [
            (.notDetermined, "Allow", "Read and send your messages"),
            (.denied, "Open Settings", "Needs a system permission"),
            (.granted, "Allowed", "Read and send your messages"),
        ]
        for (permission, button, summary) in cases {
            guard let entry else { Issue.record("no Messages entry"); return }
            let row = DeviceConnectorRow(entry: entry, state: DeviceConnectorRowState(osPermission: permission))
            let look = DeviceRowPresentation(row: row, isThisDevice: true)
            #expect(look.buttonTitle == button && look.summary == summary)
        }
    }
}

@Suite struct DeviceMessagesAccessTests {
    private static let requests: [(String, JSONValue)] = [
        ("messages.recent", [:]), ("messages.search", ["query": "x"]), ("messages.read", ["chat_id": "c"]),
        ("messages.send", ["recipient": "+15551230000", "text": "hi"]),
    ]

    @Test func untilTheOwnerAllowsItEveryActionIsRefusedWithoutTouchingTheProvider() async {
        for status in [DeviceOSPermission.notDetermined, .denied] {
            let provider = FakeMessages()
            let run = await executor(provider, permissions: FakePermissions(statuses: [.messages: status]))
            for (action, args) in Self.requests {
                let refusal = failure(await run.execute(messagesRequest(action, args: args)))
                #expect(refusal?.0 == .permissionNeeded)
            }
            #expect(provider.calls.withLock { $0.isEmpty })
        }
    }

    @Test func allowedAccessRunsTheProviderWithClampedLimits() async throws {
        let provider = FakeMessages()
        let run = await executor(provider)
        _ = await run.execute(messagesRequest("messages.recent", args: ["limit": 0, "messages_per_chat": 99]))
        _ = await run.execute(messagesRequest("messages.recent", args: ["limit": 500]))
        _ = await run.execute(messagesRequest("messages.recent"))
        _ = await run.execute(messagesRequest("messages.search", args: ["query": "  hi  ", "limit": 99]))
        _ = await run.execute(messagesRequest("messages.read", args: ["chat_id": "iMessage;-;+1555", "limit": -3]))
        #expect(provider.calls.withLock { $0 } == [
            "recent 1 10", "recent 25 3", "recent 10 3", "search hi 25", "read iMessage;-;+1555 1",
        ])
    }

    @Test func badArgumentsAreInvalidArgsAndNeverReachTheProvider() async {
        let provider = FakeMessages()
        let run = await executor(provider)
        let long = String(repeating: "a", count: 201)
        let bad: [(String, JSONValue)] = [
            ("messages.search", ["query": "   "]), ("messages.search", ["query": .string(long)]), ("messages.search", [:]),
            ("messages.read", ["chat_id": ""]), ("messages.read", ["chat_id": .string(long)]),
            ("messages.send", ["recipient": "", "text": "hi"]), ("messages.send", ["recipient": .string(long), "text": "hi"]),
            ("messages.send", ["recipient": "+1555\n0000", "text": "hi"]),
            ("messages.send", ["recipient": "+15551230000", "text": ""]),
            ("messages.send", ["recipient": "+15551230000", "text": " \n "]),
            ("messages.send", ["recipient": "+15551230000", "text": .string(String(repeating: "x", count: 4001))]),
            ("messages.send", ["recipient": "+15551230000", "text": "hi", "service": "fax"]),
        ]
        for (action, args) in bad {
            #expect(failure(await run.execute(messagesRequest(action, args: args)))?.0 == .invalidArgs)
        }
        #expect(provider.calls.withLock { $0.isEmpty })
    }

    @Test func providerErrorsKeepTheirWireCodes() async {
        let cases: [(DeviceProviderError, DeviceToolErrorCode)] = [
            (.permissionDenied, .permissionDenied), (.notFound, .notFound), (.failed("x"), .failed), (.invalidArgs("x"), .invalidArgs),
        ]
        for (error, code) in cases {
            let run = await executor(FakeMessages(failure: error))
            #expect(failure(await run.execute(messagesRequest("messages.recent")))?.0 == code)
        }
    }

    @Test func aMissingFullDiskAccessTellsTheBotWhereToLookWithoutMessageText() async throws {
        let run = await executor(FakeMessages(failure: .permissionDenied))
        let read = try #require(failure(await run.execute(messagesRequest("messages.recent"))))
        #expect(read.0 == .permissionDenied && read.1.contains("Full Disk Access"))
        let send = try #require(failure(await run.execute(messagesRequest("messages.send", args: ["recipient": "+15551230000", "text": "secret words"]))))
        #expect(send.0 == .permissionDenied && send.1.contains("Automation") && !send.1.contains("secret words"))
    }
}

#if os(macOS)
private enum FixtureError: Error {
    case sql(String)
}

private final class ChatFixture {
    let directory: URL
    var path: String { directory.appendingPathComponent("chat.db").path }
    private var writer: OpaquePointer?
    private var handles: [String: Int] = [:]

    init(wal: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pal-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sqlite3_open_v2(directory.appendingPathComponent("chat.db").path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw FixtureError.sql("open")
        }
        if wal {
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA wal_autocheckpoint=0")
        }
        try exec("""
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT, display_name TEXT);
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT, attributedBody BLOB, handle_id INTEGER, service TEXT, date INTEGER, is_from_me INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        """)
    }

    deinit {
        sqlite3_close(writer)
        try? FileManager.default.removeItem(at: directory)
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sql(sql) }
    }

    @discardableResult
    func insert(_ sql: String, _ values: [Any?]) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(writer, sql, -1, &statement, nil) == SQLITE_OK else { throw FixtureError.sql(sql) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let position = Int32(offset + 1)
            switch value {
            case let number as Int: _ = sqlite3_bind_int64(statement, position, Int64(number))
            case let number as Int64: _ = sqlite3_bind_int64(statement, position, number)
            case let text as String: _ = sqlite3_bind_text(statement, position, text, -1, transient)
            case let data as Data: _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), transient) }
            default: _ = sqlite3_bind_null(statement, position)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.sql(sql) }
        return Int(sqlite3_last_insert_rowid(writer))
    }

    func handle(_ id: String) throws -> Int {
        if let known = handles[id] { return known }
        let row = try insert("INSERT INTO handle (id) VALUES (?)", [id])
        handles[id] = row
        return row
    }

    func chat(_ guid: String, name: String? = nil, members: [String] = []) throws -> Int {
        let row = try insert("INSERT INTO chat (guid, display_name) VALUES (?, ?)", [guid, name])
        for member in members { try insert("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)", [row, try handle(member)]) }
        return row
    }

    @discardableResult
    func message(
        in chat: Int, _ text: String?, body: Data? = nil, from handle: String? = nil, mine: Bool = false, at seconds: Double, service: String = "iMessage"
    ) throws -> Int {
        let handleID: Int? = try handle.map { try self.handle($0) }
        let row = try insert(
            "INSERT INTO message (text, attributedBody, handle_id, service, date, is_from_me) VALUES (?, ?, ?, ?, ?, ?)",
            [text, body, handleID, service, Int64(seconds * 1_000_000_000), mine ? 1 : 0]
        )
        try insert("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [chat, row])
        return row
    }
}

private func typedStream(_ text: String, forms: Int = 0) -> Data {
    var bytes: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12]
    bytes += Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84, 0x08] + Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08]
    bytes += Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
    let payload = Array(text.utf8)
    if forms == 4 {
        bytes += [0x82] + (0..<4).map { UInt8((payload.count >> (8 * $0)) & 0xFF) }
    } else if payload.count >= 0x80 {
        bytes += [0x81, UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)]
    } else {
        bytes.append(UInt8(payload.count))
    }
    return Data(bytes + payload + [0x86, 0x84, 0x02] + Array("NSDictionary".utf8))
}

private struct FakeNames: MessageNameResolving {
    var known: [String: String] = [:]
    func names(for handles: [String]) -> [String: String] { known.filter { handles.contains($0.key) } }
}

private final class FakeScripts: AppleScriptRunning {
    struct Call: Equatable {
        var source: String
        var handler: String
        var parameters: [String]
    }

    let calls = Mutex<[Call]>([])
    let failureNumber: Int?

    init(failureNumber: Int? = nil) {
        self.failureNumber = failureNumber
    }

    func run(source: String, handler: String, parameters: [String]) throws {
        calls.withLock { $0.append(Call(source: source, handler: handler, parameters: parameters)) }
        if let failureNumber { throw AppleScriptFailure(number: failureNumber) }
    }
}

private final class ThrowingDatabase: ChatDatabase {
    let error: ChatDatabaseError
    let opens = Mutex<Int>(0)

    init(error: ChatDatabaseError) {
        self.error = error
    }

    func read<T>(_ body: (any ChatReading) throws -> T) throws -> T {
        opens.withLock { $0 += 1 }
        throw error
    }
}

private func provider(_ fixture: ChatFixture, names: [String: String] = [:], scripts: FakeScripts = FakeScripts()) -> MessagesProvider {
    MessagesProvider(database: SQLiteChatDatabase(path: fixture.path), names: FakeNames(known: names), scripts: scripts)
}

private func run(_ provider: MessagesProvider, _ action: String, _ args: JSONValue = [:]) async -> DeviceToolOutcome {
    await executor(provider).execute(messagesRequest(action, args: args))
}

private let base = 700_000_000.0

@Suite struct DeviceMessagesReaderTests {
    @Test func recentListsNewestChatsFirstWithTheLatestMessagesOldestFirst() async throws {
        let fixture = try ChatFixture()
        let old = try fixture.chat("iMessage;-;+15550000001", members: ["+15550000001"])
        let group = try fixture.chat("iMessage;+;chat1", name: "Trip", members: ["+15550000002", "a@example.com"])
        try fixture.message(in: old, "first", from: "+15550000001", at: base)
        try fixture.message(in: group, "g1", from: "+15550000002", at: base + 10)
        try fixture.message(in: group, "g2", mine: true, at: base + 20)
        try fixture.message(in: group, "g3", from: "a@example.com", at: base + 30)
        try fixture.message(in: group, "g4", mine: true, at: base + 40)
        let value = try #require(success(await run(provider(fixture, names: ["+15550000002": "Sam"]), "messages.recent", ["limit": 5, "messages_per_chat": 3])))
        let chats = try #require(value["conversations"]?.arrayValue)
        #expect(chats.count == 2 && value["truncated"]?.boolValue == false)
        #expect(chats[0]["chat_id"]?.stringValue == "iMessage;+;chat1" && chats[0]["title"]?.stringValue == "Trip")
        #expect(chats[1]["title"] == nil)
        let texts = chats[0]["messages"]?.arrayValue?.compactMap { $0["text"]?.stringValue }
        #expect(texts == ["g2", "g3", "g4"])
        let participants = try #require(chats[0]["participants"]?.arrayValue)
        #expect(participants[0]["handle"]?.stringValue == "+15550000002" && participants[0]["name"]?.stringValue == "Sam")
        #expect(participants[1]["name"] == nil)
        let mine = try #require(chats[0]["messages"]?.arrayValue?.first)
        #expect(mine["from_me"]?.boolValue == true && mine["sender"] == nil && mine["service"]?.stringValue == "iMessage")
        #expect(chats[0]["last_at"]?.stringValue == "2023-03-08T20:27:20+00:00")
    }

    @Test func recentCutsToTheLimitAndSaysSo() async throws {
        let fixture = try ChatFixture()
        for index in 0..<4 {
            let chat = try fixture.chat("c\(index)")
            try fixture.message(in: chat, "m\(index)", from: "h", at: base + Double(index))
        }
        let value = try #require(success(await run(provider(fixture), "messages.recent", ["limit": 3])))
        #expect(value["conversations"]?.arrayValue?.count == 3 && value["truncated"]?.boolValue == true)
        #expect(value["conversations"]?[0]?["chat_id"]?.stringValue == "c3")
    }

    @Test func textInTheAttributedBodyBlobIsReadWhenTheTextColumnIsNull() async throws {
        let fixture = try ChatFixture()
        let chat = try fixture.chat("c1")
        try fixture.message(in: chat, nil, body: typedStream("from the blob 🙂"), from: "h", at: base)
        try fixture.message(in: chat, "plain", from: "h", at: base + 1)
        try fixture.message(in: chat, nil, body: nil, from: "h", at: base + 2)
        try fixture.message(in: chat, "\u{FFFC}", from: "h", at: base + 3)
        let value = try #require(success(await run(provider(fixture), "messages.read", ["chat_id": "c1"])))
        let texts = value["messages"]?.arrayValue?.compactMap { $0["text"]?.stringValue }
        #expect(texts == ["from the blob 🙂", "plain", "[attachment]"])
    }

    @Test func rowsThatExistOnlyInTheWalAreReadWhileAWriterStaysOpen() async throws {
        let fixture = try ChatFixture(wal: true)
        let chat = try fixture.chat("c1")
        try fixture.message(in: chat, "only-in-wal-frame", from: "h", at: base)
        let main = try Data(contentsOf: URL(fileURLWithPath: fixture.path))
        #expect(main.range(of: Data("only-in-wal-frame".utf8)) == nil)
        let wal = try Data(contentsOf: URL(fileURLWithPath: fixture.path + "-wal"))
        #expect(wal.range(of: Data("only-in-wal-frame".utf8)) != nil)
        let reader = provider(fixture)
        let first = try #require(success(await run(reader, "messages.read", ["chat_id": "c1"])))
        #expect(first["messages"]?[0]?["text"]?.stringValue == "only-in-wal-frame")
        try fixture.message(in: chat, "later", from: "h", at: base + 1)
        let second = try #require(success(await run(reader, "messages.read", ["chat_id": "c1"])))
        #expect(second["messages"]?.arrayValue?.count == 2)
    }

    @Test func readReturnsTheNewestWindowAndFlagsTheRest() async throws {
        let fixture = try ChatFixture()
        let chat = try fixture.chat("c1", members: (0..<25).map { "p\($0)" })
        for index in 0..<30 { try fixture.message(in: chat, "m\(index)", from: "p0", at: base + Double(index)) }
        let value = try #require(success(await run(provider(fixture), "messages.read", ["chat_id": "c1", "limit": 20])))
        let texts = value["messages"]?.arrayValue?.compactMap { $0["text"]?.stringValue }
        #expect(texts?.first == "m10" && texts?.last == "m29" && texts?.count == 20)
        #expect(value["truncated"]?.boolValue == true)
        #expect(value["participants"]?.arrayValue?.count == MessagesLimit.participants)
    }

    @Test func anUnknownChatIsNotFound() async throws {
        let fixture = try ChatFixture()
        #expect(failure(await run(provider(fixture), "messages.read", ["chat_id": "nope"]))?.0 == .notFound)
    }

    @Test func aLongMessageIsCutAtAThousandCharactersAndMarked() async throws {
        let fixture = try ChatFixture()
        let chat = try fixture.chat("c1")
        try fixture.message(in: chat, String(repeating: "é", count: 3000), from: "h", at: base)
        let value = try #require(success(await run(provider(fixture), "messages.read", ["chat_id": "c1"])))
        let text = try #require(value["messages"]?[0]?["text"]?.stringValue)
        #expect(text.hasPrefix(String(repeating: "é", count: 1000)) && !text.hasPrefix(String(repeating: "é", count: 1001)))
        #expect(text.contains("truncated"))
    }

    @Test func theWholeResultStaysUnderTheByteBudget() async throws {
        let fixture = try ChatFixture()
        let chat = try fixture.chat("c1")
        for index in 0..<50 { try fixture.message(in: chat, String(repeating: "x", count: 950), from: "h", at: base + Double(index)) }
        let value = try #require(success(await run(provider(fixture), "messages.read", ["chat_id": "c1", "limit": 50])))
        let texts = value["messages"]?.arrayValue?.compactMap { $0["text"]?.stringValue } ?? []
        #expect(!texts.isEmpty && texts.count < 50 && value["truncated"]?.boolValue == true)
        #expect(texts.reduce(0) { $0 + $1.utf8.count } <= MessagesLimit.totalBytes)
    }

    @Test func searchEscapesPercentUnderscoreAndBackslash() async throws {
        let fixture = try ChatFixture()
        let chat = try fixture.chat("c1")
        try fixture.message(in: chat, "100% sure", from: "h", at: base)
        try fixture.message(in: chat, "100 sure", from: "h", at: base + 1)
        try fixture.message(in: chat, "a_c", from: "h", at: base + 2)
        try fixture.message(in: chat, "abc", from: "h", at: base + 3)
        try fixture.message(in: chat, #"path\to"#, from: "h", at: base + 4)
        try fixture.message(in: chat, "pathXto", from: "h", at: base + 5)
        let reader = provider(fixture)
        for (query, expected) in [("0% s", ["100% sure"]), ("a_c", ["a_c"]), (#"h\t"#, [#"path\to"#]), ("%", ["100% sure"])] {
            let value = try #require(success(await run(reader, "messages.search", ["query": .string(query)])))
            let texts = value["matches"]?.arrayValue?.compactMap { $0["message"]?["text"]?.stringValue }
            #expect(texts == expected, "query \(query)")
        }
    }

    @Test func searchFindsBlobTextNewestFirstWithItsChat() async throws {
        let fixture = try ChatFixture()
        let one = try fixture.chat("c1", name: "Lunch")
        let two = try fixture.chat("c2")
        try fixture.message(in: one, "Pizza tonight", from: "h", at: base)
        try fixture.message(in: two, nil, body: typedStream("more PIZZA later"), from: "h", at: base + 5)
        try fixture.message(in: two, nil, body: typedStream("salad"), from: "h", at: base + 6)
        let value = try #require(success(await run(provider(fixture), "messages.search", ["query": "pizza", "limit": 10])))
        let matches = try #require(value["matches"]?.arrayValue)
        #expect(matches.map { $0["chat_id"]?.stringValue } == ["c2", "c1"])
        #expect(matches[0]["message"]?["text"]?.stringValue == "more PIZZA later" && matches[0]["title"] == nil)
        #expect(matches[1]["title"]?.stringValue == "Lunch")
        #expect(value["truncated"]?.boolValue == false)
    }

    @Test func searchIsBoundedByTheLimit() async throws {
        let fixture = try ChatFixture()
        let chat = try fixture.chat("c1")
        for index in 0..<8 { try fixture.message(in: chat, "hit \(index)", from: "h", at: base + Double(index)) }
        let value = try #require(success(await run(provider(fixture), "messages.search", ["query": "hit", "limit": 5])))
        #expect(value["matches"]?.arrayValue?.count == 5 && value["truncated"]?.boolValue == true)
    }

    @Test func aSqlLookingQueryIsJustText() async throws {
        let fixture = try ChatFixture()
        let chat = try fixture.chat("c1")
        try fixture.message(in: chat, "hello", from: "h", at: base)
        let reader = provider(fixture)
        for query in ["'; DROP TABLE message; --", "\" OR 1=1 --", "x' UNION SELECT guid FROM chat --"] {
            let value = try #require(success(await run(reader, "messages.search", ["query": .string(query)])))
            #expect(value["matches"]?.arrayValue?.isEmpty == true)
        }
        let after = try #require(success(await run(reader, "messages.search", ["query": "hello"])))
        #expect(after["matches"]?.arrayValue?.count == 1)
        #expect(failure(await run(reader, "messages.read", ["chat_id": "c1' OR '1'='1"]))?.0 == .notFound)
    }

    @Test func thePathsToTheDatabaseMapToTheTypedStates() async throws {
        let missing = MessagesProvider(
            database: SQLiteChatDatabase(path: NSTemporaryDirectory() + "pal-no-such-\(UUID().uuidString)/chat.db"),
            names: FakeNames(), scripts: FakeScripts()
        )
        #expect(failure(await executor(missing).execute(messagesRequest("messages.recent")))?.0 == .failed)
        #expect(await missing.access() == .unavailable)
        #expect(SQLiteChatDatabase.classify(code: SQLITE_AUTH, statErrno: nil) == .permissionNeeded)
        #expect(SQLiteChatDatabase.classify(code: SQLITE_CANTOPEN, statErrno: EPERM) == .permissionNeeded)
        #expect(SQLiteChatDatabase.classify(code: SQLITE_CANTOPEN, statErrno: ENOENT) == .unavailable)
        #expect(SQLiteChatDatabase.classify(code: SQLITE_OK, statErrno: EPERM) == .permissionNeeded)
        #expect(SQLiteChatDatabase.classify(code: SQLITE_BUSY, statErrno: nil) == .failed)
    }

    @Test func anInjectedPermissionFailureBecomesPermissionDenied() async {
        let database = ThrowingDatabase(error: .permissionNeeded)
        let reader = MessagesProvider(database: database, names: FakeNames(), scripts: FakeScripts())
        let outcome = failure(await executor(reader).execute(messagesRequest("messages.recent")))
        #expect(outcome?.0 == .permissionDenied)
        #expect(database.opens.withLock { $0 } == 1)
    }

    @Test func aFileTheAppMayNotReadNeedsPermission() async throws {
        guard getuid() != 0 else { return }
        let fixture = try ChatFixture(wal: false)
        let reader = provider(fixture)
        chmod(fixture.path, 0)
        defer { chmod(fixture.path, 0o600) }
        #expect(failure(await executor(reader).execute(messagesRequest("messages.recent")))?.0 == .permissionDenied)
        #expect(await reader.access() == .permissionNeeded)
    }

    @Test func theDatabaseIsNeverOpenedBeforeTheOwnerAllowsIt() async {
        let database = ThrowingDatabase(error: .failed)
        let reader = MessagesProvider(database: database, names: FakeNames(), scripts: FakeScripts())
        let run = await executor(reader, permissions: FakePermissions(statuses: [.messages: .notDetermined]))
        let outcome = failure(await run.execute(messagesRequest("messages.recent")))
        #expect(outcome?.0 == .permissionNeeded && database.opens.withLock { $0 } == 0)
    }
}

@Suite struct DeviceMessagesDecoderTests {
    @Test func shortAndLongLengthFormsDecode() {
        #expect(AttributedBodyDecoder.text(from: typedStream("hi")) == "hi")
        #expect(AttributedBodyDecoder.text(from: typedStream("日本語")) == "日本語")
        let medium = String(repeating: "m", count: 300)
        #expect(AttributedBodyDecoder.text(from: typedStream(medium)) == medium)
        let huge = String(repeating: "h", count: 70_000)
        #expect(AttributedBodyDecoder.text(from: typedStream(huge, forms: 4)) == huge)
        #expect(AttributedBodyDecoder.text(from: typedStream("four", forms: 4)) == "four")
    }

    @Test func malformedAndTruncatedDataReturnsNilWithoutTrapping() {
        let good = Array(typedStream("hello world"))
        let marker = Array("NSString".utf8)
        let markerEnd = (0...(good.count - marker.count)).first { Array(good[$0..<($0 + marker.count)]) == marker }.map { $0 + marker.count } ?? 0
        #expect(AttributedBodyDecoder.text(from: Data()) == nil)
        #expect(AttributedBodyDecoder.text(from: Data([0x04, 0x0B, 0x01, 0x02])) == nil)
        #expect(AttributedBodyDecoder.text(from: Data(marker)) == nil)
        #expect(AttributedBodyDecoder.text(from: Data(good[..<markerEnd])) == nil)
        #expect(AttributedBodyDecoder.text(from: Data(good[..<(markerEnd + 5)])) == nil)
        for cut in 0..<good.count where cut < markerEnd + 5 + 11 {
            _ = AttributedBodyDecoder.text(from: Data(good[..<cut]))
        }
        #expect(AttributedBodyDecoder.text(from: Data(marker + [0x2B, 0x7F, 0x41])) == nil)
        #expect(AttributedBodyDecoder.text(from: Data(marker + [0x2B, 0x81, 0x05])) == nil)
        #expect(AttributedBodyDecoder.text(from: Data(marker + [0x2B, 0x81, 0xFF, 0xFF, 0x41])) == nil)
        #expect(AttributedBodyDecoder.text(from: Data(marker + [0x2B, 0x82, 0x01, 0x00, 0x00])) == nil)
        #expect(AttributedBodyDecoder.text(from: Data(marker + [0x2B, 0x82, 0xFF, 0xFF, 0xFF, 0xFF, 0x41])) == nil)
        #expect(AttributedBodyDecoder.text(from: Data(marker + [0x2B, 0x83, 0x01, 0x41])) == nil)
        #expect(AttributedBodyDecoder.text(from: Data(marker + [0x2B, 0x00])) == nil)
        #expect(AttributedBodyDecoder.text(from: Data(marker + [0x2B, 0x02, 0xFF, 0xFE])) == nil)
        #expect(AttributedBodyDecoder.text(from: Data(marker + [0x01, 0x94, 0x84, 0x01] + Array(repeating: 0x02, count: 20) + [0x2B, 0x01, 0x41])) == nil)
        #expect(AttributedBodyDecoder.text(from: Data(marker + [0x2B, 0x01, 0x41])) == "A")
    }
}

@Suite struct DeviceMessagesSendTests {
    private static let hostile = [
        "He said \"hi\"", #"back\slash"#, "line one\nline two", "tell application \"Finder\" to quit",
        "end tell\nquit\ntell application \"Messages\"", "emoji 🙂 日本語 é ñ", "a\" & (do shell script \"id\") & \"", "tab\tand\r\nCRLF",
    ]

    @Test func everyHostileTextArrivesByteIdenticalAsAParameterAndNeverInTheScript() async throws {
        for text in Self.hostile {
            let scripts = FakeScripts()
            let reader = provider(try ChatFixture(), scripts: scripts)
            let value = try #require(success(await run(reader, "messages.send", ["recipient": "+15551230000", "text": .string(text)])))
            #expect(value["sent"]?.boolValue == true && value["service"]?.stringValue == "imessage" && value["recipient"]?.stringValue == "+15551230000")
            let call = try #require(scripts.calls.withLock { $0 }.first)
            #expect(call.handler == "send_message" && call.source == MessagesProvider.sendScript)
            #expect(call.parameters.count == 3)
            #expect(Array(call.parameters[1].utf8) == Array(text.utf8))
            #expect(!call.source.contains(text) && !call.source.contains("+15551230000"))
        }
    }

    @Test func aHostileRecipientIsAParameterToo() async throws {
        let scripts = FakeScripts()
        let reader = provider(try ChatFixture(), scripts: scripts)
        let recipient = "x\" & (quit) & \"@example.com"
        _ = await run(reader, "messages.send", ["recipient": .string(recipient), "text": "hi", "service": "sms"])
        let call = try #require(scripts.calls.withLock { $0 }.first)
        #expect(call.parameters == [recipient, "hi", "sms"])
        #expect(!call.source.contains(recipient))
    }

    @Test func theFixedScriptHasNoPlaceholderForUserText() {
        #expect(MessagesProvider.sendScript.contains("on send_message(recipientHandle, bodyText, serviceName)"))
        #expect(MessagesProvider.sendScript.contains("send bodyText to targetBuddy"))
        #expect(!MessagesProvider.sendScript.contains("\\("))
    }

    @Test func automationDeniedIsPermissionDeniedAndEveryOtherFailureIsAShortFixedMessage() async throws {
        for (number, code) in [(-1743, DeviceToolErrorCode.permissionDenied), (-1728, .failed), (-600, .failed), (-609, .failed), (-10810, .failed)] {
            let reader = provider(try ChatFixture(), scripts: FakeScripts(failureNumber: number))
            let outcome = try #require(failure(await run(reader, "messages.send", ["recipient": "+15551230000", "text": "private words"])))
            #expect(outcome.0 == code && !outcome.1.contains("private words"))
            if code == .failed { #expect(outcome.1.count < 160) }
        }
    }

    @Test func invalidSendsNeverRunAScript() async throws {
        let scripts = FakeScripts()
        let reader = provider(try ChatFixture(), scripts: scripts)
        _ = await run(reader, "messages.send", ["recipient": "", "text": "hi"])
        _ = await run(reader, "messages.send", ["recipient": "+15551230000", "text": ""])
        #expect(scripts.calls.withLock { $0.isEmpty })
        let off = await executor(reader, state: .off)
        _ = await off.execute(messagesRequest("messages.send", args: ["recipient": "+15551230000", "text": "hi"]))
        #expect(scripts.calls.withLock { $0.isEmpty })
    }

    @Test func theRealSubroutineEventCarriesEveryParameterAsOneStringItem() throws {
        let event = NSAppleScriptRunner.subroutineEvent("send_message", ["a\"b", "line\nbreak", "imessage"])
        let name = try #require(event.paramDescriptor(forKeyword: 0x736E616D))
        #expect(name.stringValue == "send_message")
        let list = try #require(event.paramDescriptor(forKeyword: 0x2D2D2D2D))
        #expect(list.numberOfItems == 3)
        #expect((1...3).compactMap { list.atIndex($0)?.stringValue } == ["a\"b", "line\nbreak", "imessage"])
    }
}
#endif
