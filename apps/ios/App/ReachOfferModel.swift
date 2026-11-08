import Foundation
import HermesClient
import Observation

@MainActor
@Observable
final class ReachOfferModel {
    static let visibleDuration = Duration.seconds(12)

    private(set) var current: ReachOffer?

    private var queue: [ReachOffer] = []
    private let presence: ReachPresence
    private let open: @MainActor (String) -> Void

    init(presence: ReachPresence, open: @escaping @MainActor (String) -> Void) {
        self.presence = presence
        self.open = open
    }

    func listen() async {
        for await offer in presence.offers where await presence.canPresentOffers { enqueue(offer) }
    }

    func displayed(_ offer: ReachOffer) async {
        guard current == offer else { return }
        await presence.report(.shown, for: offer.offerID)
        try? await Task.sleep(for: Self.visibleDuration)
        guard !Task.isCancelled, current == offer else { return }
        advance()
    }

    func accept() {
        guard let offer = current else { return }
        Task { await presence.report(.acted, for: offer.offerID) }
        if let sessionID = offer.sessionID { open(sessionID) }
        advance()
    }

    func dismiss() {
        guard let offer = current else { return }
        Task { await presence.report(.dismissed, for: offer.offerID) }
        advance()
    }

    private func enqueue(_ offer: ReachOffer) {
        if current == nil { current = offer } else { queue.append(offer) }
    }

    private func advance() {
        current = queue.isEmpty ? nil : queue.removeFirst()
    }
}
