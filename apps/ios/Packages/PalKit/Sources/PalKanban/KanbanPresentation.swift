import Foundation
import PalTransport

public enum KanbanPresentation {
    public static let surfaceTitle = String(localized: "Pal Kanban")
    public static let verifiedIndependently = "Independently verified"
    public static let attested = "Attested by the producer (not independently verified)"
    public static let unknown = "Unknown"
    public static let refused = "Refused"
    public static let noContract = "No outcome contract"
    public static let noCiResult = "No CI result recorded"

    public static func outcomeLabel(_ outcome: KanbanOutcomeVerification) -> String {
        switch outcome.state {
        case .refused: return refused
        case .notGoverned: return noContract
        case .verified:
            switch outcome.verification {
            case .independent?: return verifiedIndependently
            case .attested?: return attested
            default: return unknown
            }
        case .unknown: return unknown
        }
    }

    public static func ciLabel(_ ci: KanbanCiAcceptance) -> String {
        switch ci.state {
        case .accepted: "CI accepted this pull request head"
        case .rejected: "CI rejected this pull request head"
        case .unknown: noCiResult
        }
    }

    public static func proofLabel(_ proof: KanbanProofHistory) -> String {
        switch proof.kind {
        case .prAcceptance:
            switch KanbanCiState(wire: proof.state) {
            case .accepted: return "CI accepted this pull request head"
            case .rejected: return "CI rejected this pull request head"
            case .unknown: return noCiResult
            }
        case .outcomeVerified, .outcomeRefused, .unknown:
            return outcomeLabel(KanbanOutcomeVerification(state: KanbanOutcomeState(wire: proof.state), verification: proof.verification))
        }
    }

    public static func evidenceSource(_ source: String) -> String {
        switch source {
        case "github", "local-file": "Checked by gateway"
        case "attestation": "Attested by producer"
        default: source.isEmpty ? unknown : source
        }
    }

    public static func evidenceTitle(_ kind: KanbanEvidenceKind) -> String {
        switch kind {
        case .executionRef: "Execution reference"
        case .prPublished: "Pull request published"
        case .prMerged: "Pull request merged"
        case .artifactBuilt: "Artifact built"
        case .appInstalled: "App installed"
        case .otherResult: "Other result"
        case .unknown(let raw): humanized(raw)
        }
    }

    public static func eventTitle(_ kind: KanbanEventKind) -> String {
        switch kind {
        case .claimed: "Claimed"
        case .evidenceRecorded: "Evidence recorded"
        case .outcomeVerified: "Outcome recorded"
        case .outcomeRefused: "Outcome refused"
        case .prAcceptance: "CI result recorded"
        case .blocked: "Blocked"
        case .completed: "Completed"
        case .unknown(let raw): humanized(raw)
        }
    }

    public static func statusTitle(_ status: KanbanCardStatus) -> String {
        switch status {
        case .triage: "Triage"
        case .todo: "To do"
        case .scheduled: "Scheduled"
        case .ready: "Ready"
        case .running: "Running"
        case .blocked: "Blocked"
        case .review: "In review"
        case .done: "Done"
        case .archived: "Archived"
        case .unknown(let raw): raw.isEmpty ? unknown : humanized(raw)
        }
    }

    public static func contractTitle(_ contract: KanbanOutcomeContract) -> String {
        switch contract.kind {
        case .mergedPR: "Merged pull request"
        case .builtArtifact: "Built artifact"
        case .installedApp: "Installed app"
        case .other: contract.name ?? "Other result"
        case .unknown(let raw): humanized(raw)
        }
    }

    public static func age(since seconds: Int?, now: Date) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let elapsed = max(0, Int(now.timeIntervalSince1970) - seconds)
        let days = elapsed / 86_400
        switch elapsed {
        case ..<60: return String(localized: "now")
        case ..<3_600: return "\(elapsed / 60)m"
        case ..<86_400: return "\(elapsed / 3_600)h"
        default:
            if days < 14 { return "\(days)d" }
            if days < 60 { return "\(days / 7)w" }
            if days < 365 { return "\(days / 30)mo" }
            return "\(days / 365)y"
        }
    }

    public static func ageSource(_ card: KanbanCard) -> Int? {
        card.completedAt ?? card.startedAt ?? card.createdAt
    }

    private static func humanized(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
