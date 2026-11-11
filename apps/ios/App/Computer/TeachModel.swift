import Foundation
import PalBotProfile
import PalChat
import Observation

enum TeachSurface: Hashable {
    case chat
    case computer
}

enum TeachConfirmation: Equatable {
    case approve
    case discardDraft
    case discardRecording
}

struct TeachControl {
    var acquire: @MainActor () async -> (viewerID: String, took: Bool)?
    var release: @MainActor () async -> Void
}

struct TeachObserveKey: Hashable {
    let kick: Int
    let active: Bool
}

@MainActor
@Observable
final class TeachModel {
    enum ReviewState: Equatable {
        case loading
        case loaded(TeachDraft)
        case failed
    }

    static let askAgainWait: TimeInterval = 90

    let botName: String
    let displayName: String
    private let service: TeachService
    private let deliver: @Sendable (_ botName: String, _ prompt: String) async throws -> Void

    private(set) var snapshot: TeachSnapshot?
    private(set) var unavailable = false
    private(set) var offline = false
    private(set) var busy = false
    private(set) var screenLive = false
    private(set) var kick = 0
    private(set) var review = ReviewState.loading
    private(set) var askAgainAt = Date.distantPast
    var showsReview = false
    var confirmation: TeachConfirmation?
    var reviewError: String?
    var toast: String?
    var surface = TeachSurface.chat
    var control: TeachControl?
    private var tookControl = false

    init(
        botName: String,
        displayName: String,
        service: TeachService,
        deliver: @escaping @Sendable (_ botName: String, _ prompt: String) async throws -> Void
    ) {
        self.botName = botName
        self.displayName = displayName
        self.service = service
        self.deliver = deliver
    }

    var phase: TeachPhase {
        guard !unavailable, let snapshot else { return .hidden }
        return snapshot.phase(live: true)
    }

    var showsBanner: Bool {
        switch phase {
        case .recording, .ended, .drafting, .ready: true
        case .hidden, .idle: false
        }
    }

    var canStart: Bool { phase == .idle && screenLive && !busy }

    func setScreenLive(_ live: Bool) {
        screenLive = live
    }

    func observe() async {
        await refresh()
        while !Task.isCancelled, let delay = snapshot?.pollDelay {
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await refresh()
        }
    }

    func refresh() async {
        do {
            snapshot = try await service.status(for: botName)
            unavailable = false
            offline = false
        } catch is CancellationError {
            return
        } catch TeachFailure.unavailable {
            unavailable = true
            snapshot = nil
        } catch {
            offline = true
        }
    }

    func start() async {
        guard canStart else { return }
        busy = true
        defer { busy = false; kick += 1 }
        guard let held = await control?.acquire() else {
            toast = String(localized: "Take control of the screen first.")
            return
        }
        do {
            snapshot = try await service.start(for: botName, viewerID: held.viewerID)
            tookControl = held.took
        } catch {
            if held.took { await control?.release() }
            toast = Self.message(for: error, fallback: String(localized: "Couldn't start recording."))
            await refresh()
        }
    }

    func stop(discard: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false; kick += 1 }
        let outcome: TeachStopOutcome
        do {
            outcome = try await service.stop(for: botName, discard: discard)
        } catch {
            toast = Self.message(for: error, fallback: String(localized: "Couldn't finish the recording."))
            await refresh()
            return
        }
        if tookControl {
            tookControl = false
            if outcome.reason != "control_returned" { await control?.release() }
        }
        if let prompt = outcome.prompt {
            await send(prompt)
        } else if !discard {
            toast = String(localized: "Nothing was recorded, so no skill was created.")
        }
        await refresh()
    }

    func askAgain() async {
        guard !busy, let teachID = snapshot?.pending?.teachID, Date() >= askAgainAt else { return }
        busy = true
        defer { busy = false; kick += 1 }
        do {
            let prompt = try await service.prompt(for: botName, teachID: teachID)
            await send(prompt)
        } catch {
            toast = Self.message(for: error, fallback: String(localized: "Couldn't ask \(displayName) again."))
        }
        await refresh()
    }

    func openReview(from surface: TeachSurface) async {
        guard let teachID = snapshot?.pending?.teachID else { return }
        self.surface = surface
        review = .loading
        reviewError = nil
        showsReview = true
        await loadDraft(teachID)
    }

    func approve() async {
        guard !busy, case .loaded(let draft) = review, draft.canApprove else { return }
        busy = true
        defer { busy = false; kick += 1 }
        reviewError = nil
        do {
            let skill = try await service.approve(for: botName, draft: draft)
            showsReview = false
            toast = String(localized: "Skill approved: \(skill)")
        } catch TeachFailure.draftChanged {
            await loadDraft(draft.teachID)
            reviewError = String(localized: "The draft changed while you were reading it. Review the new version before approving.")
        } catch {
            reviewError = Self.message(for: error, fallback: String(localized: "Couldn't approve the skill."))
        }
        await refresh()
    }

    func discardDraft() async {
        guard !busy, let teachID = snapshot?.pending?.teachID else { return }
        busy = true
        defer { busy = false; kick += 1 }
        reviewError = nil
        do {
            try await service.discard(for: botName, teachID: teachID)
            showsReview = false
            toast = String(localized: "Draft discarded.")
        } catch {
            reviewError = Self.message(for: error, fallback: String(localized: "Couldn't discard the draft."))
        }
        await refresh()
    }

    private func loadDraft(_ teachID: String) async {
        do {
            review = .loaded(try await service.draft(for: botName, teachID: teachID))
        } catch is CancellationError {
            return
        } catch {
            review = .failed
        }
    }

    private func send(_ prompt: String) async {
        do {
            try await deliver(botName, prompt)
            askAgainAt = Date().addingTimeInterval(Self.askAgainWait)
            toast = String(localized: "Sent to \(displayName). It will write the skill for you to review.")
        } catch ChatError.noBotChat {
            toast = String(localized: "Open \(displayName)'s chat once, then try again.")
        } catch {
            toast = String(localized: "Couldn't send the recording to \(displayName).")
        }
    }

    static func message(for error: any Error, fallback: String) -> String {
        switch TeachFailure.classify(error) {
        case .draftPending: String(localized: "Review or discard the previous draft first.")
        case .notInControl: String(localized: "Take control of the screen first.")
        case .recordingInProgress: String(localized: "A recording is already in progress.")
        case .unavailable: String(localized: "Teaching isn't available on this computer.")
        case .notAllowed: String(localized: "You can't teach this bot.")
        case .invalidSkill: String(localized: "The skill didn't pass its checks. Discard it and ask again.")
        case .extraFiles: String(localized: "This draft contains other files, so it can't be approved here. Discard it and ask again.")
        case .recordingDeleted: String(localized: "That recording is gone. Discard the draft and teach again.")
        case .offline: String(localized: "Couldn't reach the bot. Check your connection and try again.")
        case .draftChanged, .notReady, .failed: fallback
        }
    }
}
