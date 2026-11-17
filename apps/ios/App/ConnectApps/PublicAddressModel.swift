import Foundation
import Observation
import PalConnect

@MainActor
@Observable
final class PublicAddressModel {
    enum Report: Equatable {
        case checked(PublicAddressCheck)
        case failed(PublicAddressError)
    }

    private(set) var state: PublicAddressState?
    private(set) var result: Report?
    private(set) var serverProblem: PublicAddress.Problem?
    private(set) var isSaving = false
    private(set) var isChecking = false
    private(set) var draft = ""

    private let service: ConnectAppsService

    init(service: ConnectAppsService) {
        self.service = service
    }

    var verdict: PublicAddress.Verdict { PublicAddress.evaluate(draft) }

    var problem: PublicAddress.Problem? {
        if case .refused(let problem) = verdict { return problem }
        return serverProblem
    }

    var canSave: Bool {
        guard state != nil, !isSaving, !isChecking, serverProblem == nil else { return false }
        switch verdict {
        case .refused: return false
        case .clear: return state?.url != nil
        case .address(let url): return url != state?.url
        }
    }

    var canCheck: Bool {
        guard let saved = state?.url, !isSaving, !isChecking else { return false }
        return verdict == .address(saved)
    }

    func start() async {
        guard state == nil else { return }
        do {
            let loaded = try await service.publicAddress()
            state = loaded
            draft = loaded.url ?? ""
        } catch {
            result = .failed(Self.failure(error))
        }
    }

    func edit(_ text: String) {
        guard text != draft else { return }
        draft = text
        serverProblem = nil
    }

    func useSuggestion() {
        guard let suggestion = state?.suggestion else { return }
        edit(suggestion)
    }

    func save() async -> Bool {
        guard canSave else { return false }
        let sent: String
        switch verdict {
        case .address(let url): sent = url
        case .clear, .refused: sent = ""
        }
        isSaving = true
        result = nil
        defer { isSaving = false }
        do {
            let saved = try await service.savePublicAddress(sent)
            state = saved
            draft = saved.url ?? ""
            return true
        } catch let error as PublicAddressError {
            if case .refused(let problem) = error.reason { serverProblem = problem } else { result = .failed(error) }
            return false
        } catch {
            result = .failed(Self.failure(error))
            return false
        }
    }

    func check() async {
        guard canCheck else { return }
        isChecking = true
        result = nil
        defer { isChecking = false }
        do {
            result = .checked(try await service.checkPublicAddress())
        } catch {
            result = .failed(Self.failure(error))
        }
    }

    private static func failure(_ error: any Error) -> PublicAddressError {
        error as? PublicAddressError ?? PublicAddressError(.other)
    }
}
