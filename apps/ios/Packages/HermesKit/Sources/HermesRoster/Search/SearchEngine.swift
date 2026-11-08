import Foundation
import HermesProtocol

public enum SearchSourceError: Error, Sendable, Equatable {
    case unavailable
}

public struct SearchEngine: Sendable {
    public struct Limits: Sendable, Equatable {
        public var concurrency: Int
        public var messagesPerBot: Int
        public var messages: Int
        public var filesPerBot: Int
        public var files: Int
        public var groups: Int

        public init(concurrency: Int = 4, messagesPerBot: Int = 10, messages: Int = 50, filesPerBot: Int = 50, files: Int = 100, groups: Int = 100) {
            self.concurrency = max(1, concurrency)
            self.messagesPerBot = messagesPerBot
            self.messages = messages
            self.filesPerBot = filesPerBot
            self.files = files
            self.groups = groups
        }
    }

    private let gateway: RosterGateway
    private let limits: Limits

    public init(gateway: RosterGateway, limits: Limits = Limits()) {
        self.gateway = gateway
        self.limits = limits
    }

    public func run(_ source: SearchScope, query: String, bots: [SearchBot]) async throws -> SourceState {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let items: [SearchItem]
        var incomplete = false
        switch source {
        case .all:
            return SourceState(phase: .loaded)
        case .bots:
            items = Self.botItems(needle, bots)
        case .messages:
            (items, incomplete) = try await messageItems(needle, bots)
        case .files:
            (items, incomplete) = try await fileItems(needle, bots)
        case .routines:
            (items, incomplete) = try await routineItems(needle, bots)
        case .groupChats:
            items = try await groupItems(needle)
        }
        try Task.checkCancellation()
        return SourceState(phase: .loaded, items: items, isIncomplete: incomplete)
    }

    static func botItems(_ needle: String, _ bots: [SearchBot]) -> [SearchItem] {
        bots
            .filter { needle.isEmpty || $0.displayName.localizedStandardContains(needle) || $0.name.localizedStandardContains(needle) }
            .map { .bot(BotHit(botName: $0.name, displayName: $0.displayName)) }
    }

    private func messageItems(_ needle: String, _ bots: [SearchBot]) async throws -> ([SearchItem], Bool) {
        guard !needle.isEmpty else { return ([], false) }
        let outcomes = await perBot(bots) { bot in
            let result = try await gateway.call("session.search", [
                "query": .string(needle),
                "profile": .string(bot.name),
                "limit": .int(limits.messagesPerBot),
            ])
            return Self.messageHits(in: result, owners: bots)
        }
        let hits = try Self.merge(outcomes)
        let sorted = hits.items.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
        return (Array(sorted.prefix(limits.messages)).map(SearchItem.message), hits.incomplete)
    }

    private func fileItems(_ needle: String, _ bots: [SearchBot]) async throws -> ([SearchItem], Bool) {
        let outcomes = await perBot(bots) { bot in
            let result = try await gateway.call("library.list", [
                "profile": .string(bot.name),
                "kind": "all",
                "limit": .int(limits.filesPerBot),
            ])
            return Self.fileHits(in: result, bot: bot)
        }
        let hits = try Self.merge(outcomes)
        let matching = hits.items.filter { hit in
            needle.isEmpty || [hit.title, hit.subtitle, hit.url ?? ""].contains { $0.localizedStandardContains(needle) }
        }
        let sorted = matching.sorted { ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast) }
        return (Array(sorted.prefix(limits.files)).map(SearchItem.file), hits.incomplete)
    }

    private func routineItems(_ needle: String, _ bots: [SearchBot]) async throws -> ([SearchItem], Bool) {
        let outcomes = await perBot(bots) { bot in
            let result = try await gateway.call("cron.manage", [
                "action": "list",
                "profile": .string(bot.name),
                "include_disabled": true,
            ])
            if let failure = result["error"]?.stringValue, !failure.isEmpty { throw SearchSourceError.unavailable }
            return Self.routineHits(in: result, bot: bot)
        }
        let hits = try Self.merge(outcomes)
        let matching = hits.items.filter { hit in
            needle.isEmpty || [hit.name, hit.promptPreview, hit.schedule].contains { $0.localizedStandardContains(needle) }
        }
        let sorted = matching.sorted { lhs, rhs in
            switch (lhs.nextRunAt, rhs.nextRunAt) {
            case let (left?, right?): left < right
            case (_?, nil): true
            default: false
            }
        }
        return (sorted.map(SearchItem.routine), hits.incomplete)
    }

    private func groupItems(_ needle: String) async throws -> [SearchItem] {
        let result = try await gateway.call("groups.list", ["limit": .int(limits.groups)])
        let rooms = (result["rooms"]?.arrayValue ?? []).compactMap(Self.groupHit)
        return rooms
            .filter { room in
                needle.isEmpty || room.name.localizedStandardContains(needle)
                    || room.memberNames.contains { $0.localizedStandardContains(needle) }
            }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            .map(SearchItem.groupChat)
    }

    private func perBot<T: Sendable>(
        _ bots: [SearchBot],
        _ work: @escaping @Sendable (SearchBot) async throws -> [T]
    ) async -> [Result<[T], any Error>] {
        await withTaskGroup(of: (Int, Result<[T], any Error>).self) { group in
            var results = [Result<[T], any Error>?](repeating: nil, count: bots.count)
            var next = 0
            func launch() {
                guard next < bots.count else { return }
                let index = next
                let bot = bots[index]
                next += 1
                group.addTask {
                    do { return (index, .success(try await work(bot))) } catch { return (index, .failure(error)) }
                }
            }
            for _ in 0..<min(limits.concurrency, bots.count) { launch() }
            while let (index, outcome) = await group.next() {
                results[index] = outcome
                launch()
            }
            return results.compactMap { $0 }
        }
    }

    private static func merge<T>(_ outcomes: [Result<[T], any Error>]) throws -> (items: [T], incomplete: Bool) {
        try Task.checkCancellation()
        var items: [T] = []
        var failures: [any Error] = []
        for outcome in outcomes {
            switch outcome {
            case .success(let values): items += values
            case .failure(let error): failures.append(error)
            }
        }
        if let first = failures.first {
            if failures.contains(where: { $0 is CancellationError }) { throw CancellationError() }
            if failures.count == outcomes.count { throw first }
        }
        return (items, !failures.isEmpty)
    }
}

extension SearchEngine {
    static func messageHits(in result: JSONValue, owners: [SearchBot]) -> [MessageHit] {
        (result["results"]?.arrayValue ?? []).compactMap { row in
            guard let sessionID = row["session_id"]?.stringValue,
                  let snippet = row["snippet"]?.stringValue
            else { return nil }
            let ids = [row["resolved_id"]?.stringValue, sessionID].compactMap { $0 }
            let holders = owners.filter { owner in ids.contains { owner.sessionIDs.contains($0) } }
            let named = row["profile"]?.stringValue
            guard let owner = holders.first(where: { $0.name == named }) ?? holders.first else { return nil }
            return MessageHit(
                botName: owner.name,
                botDisplayName: owner.displayName,
                sessionID: row["resolved_id"]?.stringValue ?? sessionID,
                title: row["title"]?.stringValue,
                snippet: snippet,
                role: row["role"]?.stringValue,
                timestamp: row["timestamp"].flatMap(SearchDates.date(from:))
            )
        }
    }

    static func fileHits(in result: JSONValue, bot: SearchBot) -> [FileHit] {
        (result["items"]?.arrayValue ?? []).compactMap { row in
            guard let id = row["id"]?.stringValue, let title = row["title"]?.stringValue else { return nil }
            return FileHit(
                botName: bot.name,
                botDisplayName: bot.displayName,
                itemID: id,
                kind: row["kind"]?.stringValue.flatMap(FileHit.Kind.init(rawValue:)) ?? .other,
                title: title,
                subtitle: row["subtitle"]?.stringValue ?? "",
                url: row["url"]?.stringValue,
                assetRef: row["asset_ref"]?.stringValue,
                mime: row["mime"]?.stringValue,
                size: row["size"]?.intValue,
                sessionID: row["session_id"]?.stringValue ?? "",
                occurredAt: row["occurred_at"].flatMap(SearchDates.date(from:))
            )
        }
    }

    static func routineHits(in result: JSONValue, bot: SearchBot) -> [RoutineHit] {
        (result["jobs"]?.arrayValue ?? []).compactMap { row in
            guard let id = row["job_id"]?.stringValue else { return nil }
            let name = row["name"]?.stringValue ?? ""
            return RoutineHit(
                botName: bot.name,
                botDisplayName: bot.displayName,
                jobID: id,
                name: name.isEmpty ? (row["prompt_preview"]?.stringValue ?? id) : name,
                schedule: row["schedule_text"]?.stringValue ?? row["schedule"]?.stringValue ?? "",
                promptPreview: row["prompt_preview"]?.stringValue ?? "",
                isEnabled: row["enabled"]?.boolValue ?? true,
                nextRunAt: row["next_run_at"].flatMap(SearchDates.date(from:))
            )
        }
    }

    static func groupHit(_ row: JSONValue) -> GroupHit? {
        guard let id = row["room_id"]?.stringValue, let name = row["name"]?.stringValue else { return nil }
        let members = (row["members"]?.arrayValue ?? []).compactMap { member in
            member["display_name"]?.stringValue ?? member["handle"]?.stringValue ?? member["profile"]?.stringValue
        }
        return GroupHit(roomID: id, name: name, memberNames: members, updatedAt: row["updated_at"].flatMap(SearchDates.date(from:)))
    }
}

enum SearchDates {
    static func date(from value: JSONValue) -> Date? {
        switch value {
        case .int, .double:
            guard let number = value.numberValue else { return nil }
            return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let number = Double(trimmed) { return date(from: .double(number)) }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: trimmed) { return parsed }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: trimmed)
        default:
            return nil
        }
    }
}
