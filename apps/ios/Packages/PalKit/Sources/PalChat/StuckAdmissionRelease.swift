import PalDiagnostics
import PalProtocol
import PalTransport
import Synchronization

final class StuckAdmissionRelease: Sendable {
    static let alreadyResolvedReasons: Set<String> = ["not_found", "stale_generation"]

    private struct State {
        var inFlight: Set<String> = []
        var settled: Set<String> = []
    }

    private let state = Mutex(State())

    func claim(_ pending: [PendingAdmission]) -> [(admissionID: String, generation: Int)] {
        state.withLock { state in
            pending.compactMap { admission in
                guard admission.status == .unknown, let generation = admission.executionGeneration,
                      !state.inFlight.contains(admission.admissionID), !state.settled.contains(admission.admissionID)
                else { return nil }
                state.inFlight.insert(admission.admissionID)
                return (admission.admissionID, generation)
            }
        }
    }

    func finish(_ admissionID: String, settled: Bool) {
        state.withLock { state in
            state.inFlight.remove(admissionID)
            if settled { state.settled.insert(admissionID) }
        }
    }
}

extension SessionAPI {
    func releaseStuck(_ pending: [PendingAdmission], sessionID: String, diagnostics: Diagnostics = .osLog()) {
        for claim in stuckRelease.claim(pending) {
            Task {
                var settled = true
                do {
                    _ = try await resolveUnknown(
                        sessionID: sessionID, admissionID: claim.admissionID, executionGeneration: claim.generation
                    )
                } catch {
                    settled = RefusalReason(error).map { StuckAdmissionRelease.alreadyResolvedReasons.contains($0.reason) } ?? false
                    if !settled {
                        diagnostics.warning("chat", "interrupted message was not released: \(Diagnostics.describe(error))")
                    }
                }
                stuckRelease.finish(claim.admissionID, settled: settled)
            }
        }
    }
}
