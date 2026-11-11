import Foundation
import PalBotProfile
import Observation

@MainActor
@Observable
final class RoutinesModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed
    }

    private(set) var phase: Phase = .loading
    private(set) var routines: [Routine] = []
    private(set) var pending: Set<String> = []
    var pendingRemoval: Routine?
    var toast: String?
    var isCreating = false

    let botName: String
    private let services: BotsServices

    init(botName: String, services: BotsServices) {
        self.botName = botName
        self.services = services
    }

    func load() async {
        do {
            routines = try await services.routines.list(profile: botName)
            phase = .ready
        } catch is CancellationError {
        } catch {
            if routines.isEmpty { phase = .failed }
        }
    }

    func setEnabled(_ enabled: Bool, for routine: Routine) async {
        guard !pending.contains(routine.id), let index = routines.firstIndex(where: { $0.id == routine.id }) else { return }
        pending.insert(routine.id)
        routines[index].isEnabled = enabled
        defer { pending.remove(routine.id) }
        do {
            try await services.routines.setEnabled(enabled, routine: routine.id, profile: botName)
        } catch is CancellationError {
        } catch {
            if let current = routines.firstIndex(where: { $0.id == routine.id }) { routines[current].isEnabled = !enabled }
            toast = String(localized: "Couldn't update the routine")
        }
    }

    func remove(_ routine: Routine) async {
        pendingRemoval = nil
        do {
            try await services.routines.remove(routine: routine.id, profile: botName)
            routines.removeAll { $0.id == routine.id }
        } catch is CancellationError {
        } catch {
            toast = String(localized: "Couldn't delete the routine")
        }
    }

    func creationModel() -> NewRoutineModel {
        NewRoutineModel(botName: botName, services: services) { [weak self] in
            await self?.load()
        }
    }
}

@MainActor
@Observable
final class NewRoutineModel {
    enum Preview: Equatable {
        case idle
        case checking
        case accepted(SchedulePreview)
        case refused(String)
    }

    var title = ""
    var prompt = ""
    var schedule = "" {
        didSet { if schedule != oldValue { schedulePreviewTask() } }
    }
    private(set) var preview: Preview = .idle
    private(set) var isSaving = false
    private(set) var failure: String?

    private let botName: String
    private let services: BotsServices
    private let onCreated: () async -> Void
    private var previewTask: Task<Void, Never>?

    static let debounce: Duration = .milliseconds(450)

    init(botName: String, services: BotsServices, onCreated: @escaping () async -> Void) {
        self.botName = botName
        self.services = services
        self.onCreated = onCreated
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedSchedule: String { schedule.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canSave: Bool {
        if case .accepted = preview { return !trimmedTitle.isEmpty && !trimmedPrompt.isEmpty && !isSaving }
        return false
    }

    private func schedulePreviewTask() {
        previewTask?.cancel()
        failure = nil
        guard !trimmedSchedule.isEmpty else {
            preview = .idle
            return
        }
        preview = .checking
        let phrase = trimmedSchedule
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard let self, !Task.isCancelled else { return }
            do {
                let result = try await services.routines.preview(schedule: phrase, profile: botName)
                guard !Task.isCancelled else { return }
                preview = .accepted(result)
            } catch let RoutineError.scheduleRefused(reason) {
                guard !Task.isCancelled else { return }
                preview = .refused(reason.message)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                preview = .refused(String(localized: "Couldn't check that schedule. Try again."))
            }
        }
    }

    func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        failure = nil
        defer { isSaving = false }
        do {
            try await services.routines.add(title: trimmedTitle, prompt: trimmedPrompt, schedule: trimmedSchedule, profile: botName)
        } catch let RoutineError.scheduleRefused(reason) {
            preview = .refused(reason.message)
            return false
        } catch {
            failure = String(localized: "Couldn't create the routine. Try again.")
            return false
        }
        await onCreated()
        return true
    }
}
