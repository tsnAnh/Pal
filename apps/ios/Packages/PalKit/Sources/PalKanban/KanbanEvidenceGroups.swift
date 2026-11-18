import Foundation
import PalTransport

public struct KanbanEvidenceGroup: Sendable, Equatable, Identifiable {
    public static let visibleLimit = 3

    public let kind: KanbanEvidenceKind
    public let url: URL?
    public let summary: String?
    public let count: Int
    public let latest: KanbanEvidence

    public var id: String { "\(kind.wire)|\(url?.absoluteString ?? summary ?? "")" }

    public static func groups(_ evidence: [KanbanEvidence]) -> [KanbanEvidenceGroup] {
        var byKey: [String: [KanbanEvidence]] = [:]
        for item in evidence {
            byKey[key(item), default: []].append(item)
        }
        return byKey.values
            .compactMap { items -> KanbanEvidenceGroup? in
                guard let latest = items.max(by: { isNewer($1, than: $0) }) else { return nil }
                return KanbanEvidenceGroup(kind: latest.kind, url: latest.url, summary: latest.summary, count: items.count, latest: latest)
            }
            .sorted { isNewer($0.latest, than: $1.latest) }
    }

    private static func key(_ item: KanbanEvidence) -> String {
        "\(item.kind.wire)|\(item.url?.absoluteString ?? item.summary ?? "")"
    }

    private static func isNewer(_ lhs: KanbanEvidence, than rhs: KanbanEvidence) -> Bool {
        (lhs.observedAt ?? 0, lhs.evidenceID) > (rhs.observedAt ?? 0, rhs.evidenceID)
    }
}
