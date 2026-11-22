import Foundation
import Observation
import PalProtocol

public struct ChatDeskCard: Identifiable, Sendable, Hashable {
    public enum Answer: Sendable, Hashable {
        case sending(ChatDeskChoice)
        case failed
    }

    public var item: ChatDeskItemWire
    public var answer: Answer?
    public var id: String { item.id }
}

@MainActor
@Observable
public final class ChatDeskModel {
    public private(set) var cards: [ChatDeskCard] = []

    private let client: any ChatMemberClient

    public var newestFirst: [ChatDeskCard] { cards.reversed() }

    public init(client: any ChatMemberClient) {
        self.client = client
    }

    public func load() async {
        guard let items = try? await client.desk() else { return }
        let waiting = Set(items.map(\.id))
        let decided = cards.filter { !waiting.contains($0.id) && !$0.item.isWaiting }
        let fresh = items.map { item in
            ChatDeskCard(item: item, answer: cards.first { $0.id == item.id }.flatMap(\.answer))
        }
        cards = (fresh + decided).sorted { $0.item.createdAt < $1.item.createdAt }
    }

    public func receive(_ payload: ChatDeskChangedPayload) {
        let item = payload.item
        guard let index = cards.firstIndex(where: { $0.id == item.id }) else {
            if item.isWaiting, Self.isOwnerDecision(item.kind) { insert(ChatDeskCard(item: item)) }
            return
        }
        guard item.revision >= cards[index].item.revision else { return }
        cards[index].item = item
        if !item.isWaiting || cards[index].answer == .failed { cards[index].answer = nil }
    }

    public func decide(_ id: String, _ choice: ChatDeskChoice) async {
        guard let index = cards.firstIndex(where: { $0.id == id }), cards[index].item.isWaiting,
              !isSending(cards[index]) else { return }
        let seen = cards[index].item
        cards[index].answer = .sending(choice)
        do {
            let decided = try await client.decide(itemId: id, choice: choice, expectedRevision: seen.revision)
            update(id) { $0.item = decided; $0.answer = nil }
        } catch is CancellationError {
            update(id) { $0.answer = nil }
        } catch ChatInstallClientError.staleRevision {
            update(id) { $0.answer = nil }
            await load()
        } catch {
            update(id) { $0.answer = .failed }
        }
    }

    private func isSending(_ card: ChatDeskCard) -> Bool {
        if case .sending = card.answer { true } else { false }
    }

    private func update(_ id: String, _ change: (inout ChatDeskCard) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        change(&cards[index])
    }

    private func insert(_ card: ChatDeskCard) {
        cards.append(card)
        cards.sort { $0.item.createdAt < $1.item.createdAt }
    }

    static func isOwnerDecision(_ kind: ChatDeskItemKind) -> Bool {
        kind == .handoff || kind == .send
    }
}
