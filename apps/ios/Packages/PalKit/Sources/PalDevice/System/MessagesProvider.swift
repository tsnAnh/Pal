import Foundation

public enum MessagesAccessProbe {
    public static func current() -> MessagesAccess {
        #if os(macOS)
        SQLiteChatDatabase.access(path: SQLiteChatDatabase.defaultPath)
        #else
        .unavailable
        #endif
    }
}

#if os(macOS)
import Contacts
import SQLite3

enum ChatDatabaseError: Error, Equatable {
    case permissionNeeded
    case unavailable
    case failed
}

struct ChatRow: Sendable, Equatable {
    var rowID: Int
    var guid: String
    var displayName: String?
    var lastDate: Date?
}

struct StoredMessage: Sendable, Equatable {
    var rowID: Int
    var date: Date
    var isFromMe: Bool
    var handle: String?
    var service: String?
    var text: String?
    var body: Data?
}

struct StoredMatch: Sendable, Equatable {
    var chat: ChatRow
    var message: StoredMessage
}

protocol ChatReading {
    func recentChats(limit: Int) throws -> [ChatRow]
    func chat(guid: String) throws -> ChatRow?
    func participants(chatRowID: Int, limit: Int) throws -> [String]
    func messages(chatRowID: Int, limit: Int) throws -> [StoredMessage]
    func textMatches(pattern: String, window: Int, limit: Int) throws -> [StoredMatch]
    func bodyCandidates(limit: Int) throws -> [StoredMatch]
}

protocol ChatDatabase: Sendable {
    func read<T>(_ body: (any ChatReading) throws -> T) throws -> T
}

protocol MessageNameResolving: Sendable {
    func names(for handles: [String]) -> [String: String]
}

protocol AppleScriptRunning: Sendable {
    func run(source: String, handler: String, parameters: [String]) throws
}

struct AppleScriptFailure: Error, Equatable {
    var number: Int
}

enum AttributedBodyDecoder {
    private static let marker = Array("NSString".utf8)
    private static let lookahead = 16
    private static let maximumBytes = 1 << 20

    static func text(from data: Data) -> String? {
        let bytes = [UInt8](data.prefix(maximumBytes))
        guard let found = position(of: marker, in: bytes) else { return nil }
        var index = found + marker.count
        let limit = min(bytes.count, index + lookahead)
        while index < limit, bytes[index] != 0x2B { index += 1 }
        guard index < limit else { return nil }
        index += 1
        guard let (count, start) = readLength(in: bytes, at: index) else { return nil }
        guard count > 0, count <= bytes.count - start else { return nil }
        return String(bytes: bytes[start..<(start + count)], encoding: .utf8)
    }

    private static func readLength(in bytes: [UInt8], at index: Int) -> (Int, Int)? {
        guard index < bytes.count else { return nil }
        let first = bytes[index]
        switch first {
        case 0x00...0x7F:
            return (Int(first), index + 1)
        case 0x81:
            guard bytes.count - index >= 3 else { return nil }
            return (Int(bytes[index + 1]) | Int(bytes[index + 2]) << 8, index + 3)
        case 0x82:
            guard bytes.count - index >= 5 else { return nil }
            let value = (0..<4).reduce(0) { $0 | Int(bytes[index + 1 + $1]) << (8 * $1) }
            return (value, index + 5)
        default:
            return nil
        }
    }

    private static func position(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) { return start }
        }
        return nil
    }
}

enum ChatDate {
    static func date(fromRaw raw: Int64) -> Date {
        let seconds = abs(raw) > 100_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}

struct SQLiteChatDatabase: ChatDatabase {
    let path: String

    static var defaultPath: String { NSHomeDirectory() + "/Library/Messages/chat.db" }

    func read<T>(_ body: (any ChatReading) throws -> T) throws -> T {
        try body(try SQLiteChatSession(path: path))
    }

    static func access(path: String) -> MessagesAccess {
        do {
            _ = try SQLiteChatDatabase(path: path).read { _ in true }
            return .ready
        } catch ChatDatabaseError.permissionNeeded {
            return .permissionNeeded
        } catch {
            return .unavailable
        }
    }

    static func classify(code: Int32, statErrno: Int32?) -> ChatDatabaseError {
        if statErrno == ENOENT { return .unavailable }
        if code == SQLITE_AUTH || code == SQLITE_PERM || code == SQLITE_CANTOPEN { return .permissionNeeded }
        if statErrno == EPERM || statErrno == EACCES { return .permissionNeeded }
        return .failed
    }
}

private final class SQLiteChatSession: ChatReading {
    private enum Binding {
        case int(Int64)
        case text(String)
    }

    private static let busyMilliseconds: Int32 = 1000
    private static let maximumBlob = 1 << 20
    private static let messageColumns = "m.ROWID, m.date, m.is_from_me, h.id, m.service, m.text, m.attributedBody"

    private var handle: OpaquePointer?

    init(path: String) throws {
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        handle = opened
        guard code == SQLITE_OK, opened != nil else {
            var info = stat()
            let statErrno: Int32? = stat(path, &info) == 0 ? nil : errno
            sqlite3_close_v2(opened)
            handle = nil
            throw SQLiteChatDatabase.classify(code: code, statErrno: statErrno)
        }
        sqlite3_busy_timeout(opened, Self.busyMilliseconds)
        do {
            _ = try rows("SELECT 1 FROM sqlite_master LIMIT 1", []) { _ in 0 }
        } catch {
            sqlite3_close_v2(handle)
            handle = nil
            throw error
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func recentChats(limit: Int) throws -> [ChatRow] {
        try rows(
            """
            SELECT c.ROWID, c.guid, c.display_name, MAX(m.date)
            FROM chat c
            JOIN chat_message_join j ON j.chat_id = c.ROWID
            JOIN message m ON m.ROWID = j.message_id
            GROUP BY c.ROWID
            ORDER BY MAX(m.date) DESC, c.ROWID DESC
            LIMIT ?
            """,
            [.int(Int64(limit))]
        ) { chatRow($0, at: 0) }
    }

    func chat(guid: String) throws -> ChatRow? {
        try rows(
            """
            SELECT c.ROWID, c.guid, c.display_name,
                (SELECT MAX(m.date) FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id WHERE j.chat_id = c.ROWID)
            FROM chat c WHERE c.guid = ? LIMIT 1
            """,
            [.text(guid)]
        ) { chatRow($0, at: 0) }.first
    }

    func participants(chatRowID: Int, limit: Int) throws -> [String] {
        try rows(
            """
            SELECT h.id FROM chat_handle_join cj JOIN handle h ON h.ROWID = cj.handle_id
            WHERE cj.chat_id = ? ORDER BY h.ROWID LIMIT ?
            """,
            [.int(Int64(chatRowID)), .int(Int64(limit))]
        ) { text($0, 0) }.compactMap { $0 }
    }

    func messages(chatRowID: Int, limit: Int) throws -> [StoredMessage] {
        try rows(
            """
            SELECT \(Self.messageColumns)
            FROM message m
            JOIN chat_message_join j ON j.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE j.chat_id = ?
            ORDER BY m.date DESC, m.ROWID DESC
            LIMIT ?
            """,
            [.int(Int64(chatRowID)), .int(Int64(limit))]
        ) { storedMessage($0, at: 0) }
    }

    func textMatches(pattern: String, window: Int, limit: Int) throws -> [StoredMatch] {
        try rows(
            #"""
            SELECT c.ROWID, c.guid, c.display_name, \#(Self.messageColumns)
            FROM (SELECT ROWID, date, is_from_me, handle_id, service, text, attributedBody FROM message ORDER BY date DESC LIMIT ?) m
            JOIN chat_message_join j ON j.message_id = m.ROWID
            JOIN chat c ON c.ROWID = j.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.text LIKE ? ESCAPE '\'
            ORDER BY m.date DESC, m.ROWID DESC
            LIMIT ?
            """#,
            [.int(Int64(window)), .text(pattern), .int(Int64(limit))]
        ) { StoredMatch(chat: chatRow($0, at: 0, lastDate: nil), message: storedMessage($0, at: 3)) }
    }

    func bodyCandidates(limit: Int) throws -> [StoredMatch] {
        try rows(
            """
            SELECT c.ROWID, c.guid, c.display_name, \(Self.messageColumns)
            FROM (
                SELECT ROWID, date, is_from_me, handle_id, service, text, attributedBody FROM message
                WHERE text IS NULL AND attributedBody IS NOT NULL ORDER BY date DESC LIMIT ?
            ) m
            JOIN chat_message_join j ON j.message_id = m.ROWID
            JOIN chat c ON c.ROWID = j.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            ORDER BY m.date DESC, m.ROWID DESC
            """,
            [.int(Int64(limit))]
        ) { StoredMatch(chat: chatRow($0, at: 0, lastDate: nil), message: storedMessage($0, at: 3)) }
    }

    private func rows<T>(_ sql: String, _ bindings: [Binding], map: (OpaquePointer) -> T) throws -> [T] {
        var prepared: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        guard prepareCode == SQLITE_OK, let statement = prepared else {
            sqlite3_finalize(prepared)
            throw SQLiteChatDatabase.classify(code: prepareCode, statErrno: nil)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, binding) in bindings.enumerated() {
            let position = Int32(offset + 1)
            let code: Int32 = switch binding {
            case .int(let value): sqlite3_bind_int64(statement, position, value)
            case .text(let value): sqlite3_bind_text(statement, position, value, -1, transient)
            }
            guard code == SQLITE_OK else { throw ChatDatabaseError.failed }
        }
        var collected: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                collected.append(map(statement))
            } else if step == SQLITE_DONE {
                return collected
            } else {
                throw SQLiteChatDatabase.classify(code: step, statErrno: nil)
            }
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }

    private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB, let raw = sqlite3_column_blob(statement, column) else { return nil }
        let count = min(Int(sqlite3_column_bytes(statement, column)), Self.maximumBlob)
        return count > 0 ? Data(bytes: raw, count: count) : nil
    }

    private func chatRow(_ statement: OpaquePointer, at column: Int32) -> ChatRow {
        chatRow(statement, at: column, lastDate: sqlite3_column_type(statement, column + 3) == SQLITE_NULL
            ? nil : ChatDate.date(fromRaw: sqlite3_column_int64(statement, column + 3)))
    }

    private func chatRow(_ statement: OpaquePointer, at column: Int32, lastDate: Date?) -> ChatRow {
        ChatRow(
            rowID: Int(sqlite3_column_int64(statement, column)), guid: text(statement, column + 1) ?? "",
            displayName: text(statement, column + 2), lastDate: lastDate
        )
    }

    private func storedMessage(_ statement: OpaquePointer, at column: Int32) -> StoredMessage {
        StoredMessage(
            rowID: Int(sqlite3_column_int64(statement, column)),
            date: ChatDate.date(fromRaw: sqlite3_column_int64(statement, column + 1)),
            isFromMe: sqlite3_column_int(statement, column + 2) != 0,
            handle: text(statement, column + 3), service: text(statement, column + 4),
            text: text(statement, column + 5), body: blob(statement, column + 6)
        )
    }
}

struct SystemMessageNames: MessageNameResolving {
    static let maximumLookups = 100

    func names(for handles: [String]) -> [String: String] {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: break
        default: return [:]
        }
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        var found: [String: String] = [:]
        for handle in handles.prefix(Self.maximumLookups) {
            let predicate = handle.contains("@")
                ? CNContact.predicateForContacts(matchingEmailAddress: handle)
                : CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: handle))
            guard let contact = try? store.unifiedContacts(matching: predicate, keysToFetch: keys).first,
                  let name = CNContactFormatter.string(from: contact, style: .fullName), !name.isEmpty
            else { continue }
            found[handle] = name
        }
        return found
    }
}

struct NSAppleScriptRunner: AppleScriptRunning {
    func run(source: String, handler: String, parameters: [String]) throws {
        guard let script = NSAppleScript(source: source) else { throw AppleScriptFailure(number: -1) }
        var compileInfo: NSDictionary?
        guard script.compileAndReturnError(&compileInfo) else { throw AppleScriptFailure(number: Self.errorNumber(compileInfo)) }
        var info: NSDictionary?
        _ = script.executeAppleEvent(Self.subroutineEvent(handler, parameters), error: &info)
        if let info { throw AppleScriptFailure(number: Self.errorNumber(info)) }
    }

    static func subroutineEvent(_ handler: String, _ parameters: [String]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: fourCC("ascr"), eventID: fourCC("psbr"), targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: -1, transactionID: 0
        )
        event.setParam(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: fourCC("snam"))
        let list = NSAppleEventDescriptor.list()
        for (offset, parameter) in parameters.enumerated() { list.insert(NSAppleEventDescriptor(string: parameter), at: offset + 1) }
        event.setParam(list, forKeyword: fourCC("----"))
        return event
    }

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func errorNumber(_ info: NSDictionary?) -> Int {
        (info?["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue ?? -1
    }
}

public struct MessagesProvider: MessagesProviding {
    static let sendHandler = "send_message"
    static let sendScript = """
    on send_message(recipientHandle, bodyText, serviceName)
        tell application "Messages"
            if serviceName is "sms" then
                set targetService to 1st account whose service type = SMS
            else
                set targetService to 1st account whose service type = iMessage
            end if
            set targetBuddy to participant recipientHandle of targetService
            send bodyText to targetBuddy
        end tell
    end send_message
    """
    static let textWindow = 20_000
    static let bodyScan = 5000
    static let automationDenied = [-1743, -1744]

    private let database: any ChatDatabase
    private let names: any MessageNameResolving
    private let scripts: any AppleScriptRunning

    init(database: any ChatDatabase, names: any MessageNameResolving, scripts: any AppleScriptRunning) {
        self.database = database
        self.names = names
        self.scripts = scripts
    }

    public static func system() -> MessagesProvider {
        MessagesProvider(database: SQLiteChatDatabase(path: SQLiteChatDatabase.defaultPath), names: SystemMessageNames(), scripts: NSAppleScriptRunner())
    }

    public func access() async -> MessagesAccess {
        (try? await blocking { SQLiteChatDatabase.access(path: SQLiteChatDatabase.defaultPath) }) ?? .unavailable
    }

    public func recent(limit: Int, messagesPerChat: Int) async throws -> MessagesRecentRecord {
        let database = database
        let loaded = try await blocking { () throws -> MessagesRecentRecord in
            try Self.mapped {
                try database.read { (reader: any ChatReading) throws -> MessagesRecentRecord in
                    let chats = try reader.recentChats(limit: limit + 1)
                    let conversations = try chats.prefix(limit).map { try Self.conversation(reader, $0, messageLimit: messagesPerChat).0 }
                    return MessagesRecentRecord(conversations: conversations, truncated: chats.count > limit)
                }
            }
        }
        return MessagesRecentRecord(conversations: await named(loaded.conversations), truncated: loaded.truncated)
    }

    public func read(chatID: String, limit: Int) async throws -> MessagesReadRecord {
        let database = database
        let loaded = try await blocking { () throws -> MessagesReadRecord in
            try Self.mapped {
                try database.read { (reader: any ChatReading) throws -> MessagesReadRecord in
                    guard let chat = try reader.chat(guid: chatID) else { throw DeviceProviderError.notFound }
                    let (conversation, more) = try Self.conversation(reader, chat, messageLimit: limit)
                    return MessagesReadRecord(conversation: conversation, truncated: more)
                }
            }
        }
        return MessagesReadRecord(conversation: await named([loaded.conversation])[0], truncated: loaded.truncated)
    }

    public func search(query: String, limit: Int) async throws -> MessagesSearchRecord {
        let database = database
        let loaded = try await blocking { () throws -> MessagesSearchRecord in
            try Self.mapped {
                try database.read { (reader: any ChatReading) throws -> MessagesSearchRecord in
                let pattern = "%" + Self.escapeLike(query) + "%"
                var candidates = try reader.textMatches(pattern: pattern, window: Self.textWindow, limit: limit + 1)
                for candidate in try reader.bodyCandidates(limit: Self.bodyScan) {
                    guard let decoded = candidate.message.body.flatMap(AttributedBodyDecoder.text(from:)),
                          decoded.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    else { continue }
                    var found = candidate
                    found.message.text = decoded
                    candidates.append(found)
                }
                var seen = Set<Int>()
                let ordered = candidates
                    .sorted { ($0.message.date, $0.message.rowID) > ($1.message.date, $1.message.rowID) }
                    .filter { seen.insert($0.message.rowID).inserted }
                let matches = ordered.prefix(limit).compactMap { match -> MessageMatchRecord? in
                    guard let message = Self.record(match.message) else { return nil }
                    return MessageMatchRecord(chatID: match.chat.guid, title: Self.title(match.chat), message: message)
                }
                return MessagesSearchRecord(matches: matches, truncated: ordered.count > limit)
                }
            }
        }
        let resolved = await resolve(Self.handles(in: loaded.matches.map(\.message)))
        let matches = loaded.matches.map { match -> MessageMatchRecord in
            var copy = match
            copy.message.senderName = copy.message.sender.flatMap { resolved[$0] }
            return copy
        }
        return MessagesSearchRecord(matches: matches, truncated: loaded.truncated)
    }

    public func send(recipient: String, text: String, service: MessageService?) async throws -> MessageSentRecord {
        let scripts = scripts
        let chosen = service ?? .imessage
        do {
            _ = try await blocking {
                try scripts.run(source: Self.sendScript, handler: Self.sendHandler, parameters: [recipient, text, chosen.rawValue])
                return true
            }
        } catch let failure as AppleScriptFailure {
            throw Self.sendError(failure.number)
        }
        return MessageSentRecord(service: chosen, recipient: recipient)
    }

    static func sendError(_ number: Int) -> DeviceProviderError {
        if automationDenied.contains(number) { return .permissionDenied }
        return .failed("Messages could not send that message. Open Messages, check that you are signed in and that the recipient is right, then try again.")
    }

    static func escapeLike(_ query: String) -> String {
        var escaped = ""
        for character in query {
            if character == "\\" || character == "%" || character == "_" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private static func title(_ chat: ChatRow) -> String? {
        guard let name = chat.displayName, !name.isEmpty else { return nil }
        return name
    }

    private static func record(_ stored: StoredMessage) -> MessageRecord? {
        let column = stored.text.flatMap { $0.isEmpty ? nil : $0 }
        guard let raw = column ?? stored.body.flatMap(AttributedBodyDecoder.text(from:)) else { return nil }
        let text = raw.replacingOccurrences(of: "\u{FFFC}", with: "[attachment]")
        guard !text.isEmpty else { return nil }
        return MessageRecord(
            id: stored.rowID, at: stored.date, fromMe: stored.isFromMe, sender: stored.isFromMe ? nil : stored.handle,
            text: text, service: stored.service
        )
    }

    private static func conversation(_ reader: any ChatReading, _ chat: ChatRow, messageLimit: Int) throws -> (ConversationRecord, Bool) {
        let handles = try reader.participants(chatRowID: chat.rowID, limit: MessagesLimit.participants)
        let stored = try reader.messages(chatRowID: chat.rowID, limit: messageLimit + 1)
        let newest = stored.prefix(messageLimit).reversed().compactMap(record)
        let conversation = ConversationRecord(
            chatID: chat.guid, title: title(chat), participants: handles.map { MessageParticipantRecord(handle: $0) },
            lastAt: chat.lastDate ?? stored.first?.date ?? Date(timeIntervalSince1970: 0), messages: Array(newest)
        )
        return (conversation, stored.count > messageLimit)
    }

    private static func handles(in messages: [MessageRecord]) -> [String] {
        Array(Set(messages.compactMap(\.sender))).sorted()
    }

    private func resolve(_ handles: [String]) async -> [String: String] {
        let names = names
        return (try? await blocking { names.names(for: handles) }) ?? [:]
    }

    private func named(_ conversations: [ConversationRecord]) async -> [ConversationRecord] {
        let wanted = conversations.flatMap { conversation in
            conversation.participants.map(\.handle) + Self.handles(in: conversation.messages)
        }
        let resolved = await resolve(Array(Set(wanted)).sorted())
        guard !resolved.isEmpty else { return conversations }
        return conversations.map { conversation in
            var copy = conversation
            copy.participants = conversation.participants.map { MessageParticipantRecord(handle: $0.handle, name: resolved[$0.handle]) }
            copy.messages = conversation.messages.map { message in
                var named = message
                named.senderName = message.sender.flatMap { resolved[$0] }
                return named
            }
            if copy.title == nil, copy.participants.count == 1 { copy.title = copy.participants[0].name }
            return copy
        }
    }

    private static func mapped<T>(_ work: () throws -> T) throws -> T {
        do {
            return try work()
        } catch let error as ChatDatabaseError {
            switch error {
            case .permissionNeeded: throw DeviceProviderError.permissionDenied
            case .unavailable: throw DeviceProviderError.failed("Messages isn't available on this Mac.")
            case .failed: throw DeviceProviderError.failed("Messages could not be read.")
            }
        }
    }

    private func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
#endif
