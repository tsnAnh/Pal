#if canImport(AlarmKit) && os(iOS)
import AlarmKit
import Foundation
import SwiftUI

struct HermesAlarmMetadata: AlarmMetadata {}

public struct SystemAlarms: AlarmsProviding {
    private struct Stored: Codable {
        var label: String?
        var at: Date
        var weekdays: [String]
    }

    private static let defaultsKey = "dev.tsnanh.hermes.device.alarms"

    private var defaults: UserDefaults { .standard }

    public init() {}

    public func setAlarm(at: Date, label: String?, repeatWeekdays: [Weekday]) async throws -> AlarmRecord {
        let id = UUID()
        let schedule: Alarm.Schedule
        if repeatWeekdays.isEmpty {
            schedule = .fixed(at)
        } else {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: at)
            let time = Alarm.Schedule.Relative.Time(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
            let days = repeatWeekdays.compactMap { Locale.Weekday(rawValue: $0.rawValue) }
            schedule = .relative(.init(time: time, repeats: .weekly(days)))
        }
        let configuration = AlarmManager.AlarmConfiguration<HermesAlarmMetadata>.alarm(schedule: schedule, attributes: attributes(label: label))
        do { _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration) } catch { throw Self.failure(error) }
        save(id, Stored(label: label, at: at, weekdays: repeatWeekdays.map(\.rawValue)))
        return AlarmRecord(id: id.uuidString, label: label, at: at, isEnabled: true, repeatWeekdays: repeatWeekdays)
    }

    public func alarms() async throws -> [AlarmRecord] {
        let live: [Alarm]
        do { live = try AlarmManager.shared.alarms } catch { throw Self.failure(error) }
        let stored = load()
        let liveIDs = Set(live.map { $0.id.uuidString })
        let pruned = stored.filter { liveIDs.contains($0.key) }
        if pruned.count != stored.count { write(pruned) }
        return pruned
            .map { id, value in
                AlarmRecord(id: id, label: value.label, at: value.at, isEnabled: true, repeatWeekdays: value.weekdays.compactMap(Weekday.init(rawValue:)))
            }
            .sorted { $0.at < $1.at }
    }

    public func startTimer(seconds: Int, label: String?) async throws -> TimerRecord {
        let id = UUID()
        let configuration = AlarmManager.AlarmConfiguration<HermesAlarmMetadata>.timer(duration: TimeInterval(seconds), attributes: attributes(label: label))
        do { _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration) } catch { throw Self.failure(error) }
        return TimerRecord(id: id.uuidString, label: label, seconds: seconds, endsAt: Date().addingTimeInterval(TimeInterval(seconds)))
    }

    private func attributes(label: String?) -> AlarmAttributes<HermesAlarmMetadata> {
        let title = LocalizedStringResource(stringLiteral: label?.isEmpty == false ? label! : "Alarm")
        let presentation = AlarmPresentation(
            alert: .init(title: title, stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")),
            countdown: .init(title: title)
        )
        return AlarmAttributes(presentation: presentation, metadata: HermesAlarmMetadata(), tintColor: .blue)
    }

    private static func failure(_ error: any Error) -> DeviceProviderError {
        if let alarmError = error as? AlarmManager.AlarmError, alarmError == .maximumLimitReached {
            return .failed("The iPhone has reached its limit of alarms.")
        }
        return .failed("The alarm could not be set.")
    }

    private func load() -> [String: Stored] {
        guard let data = defaults.data(forKey: Self.defaultsKey), let decoded = try? JSONDecoder().decode([String: Stored].self, from: data) else { return [:] }
        return decoded
    }

    private func write(_ value: [String: Stored]) {
        defaults.set(try? JSONEncoder().encode(value), forKey: Self.defaultsKey)
    }

    private func save(_ id: UUID, _ value: Stored) {
        var all = load()
        all[id.uuidString] = value
        write(all)
    }
}
#endif
