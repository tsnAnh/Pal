import Foundation
import PalProtocol

public struct DeviceToolEnvironment: Sendable {
    public var timeZone: @Sendable () -> TimeZone
    public var deadlineMargin: Duration

    public init(timeZone: @escaping @Sendable () -> TimeZone = { .current }, deadlineMargin: Duration = .milliseconds(500)) {
        self.timeZone = timeZone
        self.deadlineMargin = deadlineMargin
    }
}

public actor DeviceToolExecutor {
    private let providers: DeviceProviders
    private let permissions: any DevicePermissions
    private let ledger: ConnectorLedger
    private let consent: any ConsentPrompting
    private let environment: DeviceToolEnvironment

    public init(
        providers: DeviceProviders,
        permissions: any DevicePermissions,
        ledger: ConnectorLedger,
        consent: any ConsentPrompting,
        environment: DeviceToolEnvironment = DeviceToolEnvironment()
    ) {
        self.providers = providers
        self.permissions = permissions
        self.ledger = ledger
        self.consent = consent
        self.environment = environment
    }

    public func execute(_ request: DeviceToolRequest) async -> DeviceToolOutcome {
        let seconds = max(1, request.deadlineSeconds)
        let budget = Duration.seconds(seconds) - environment.deadlineMargin
        return await Self.withDeadline(budget) { [self] in await run(request, budget: budget) }
    }

    private static func withDeadline(_ limit: Duration, _ work: @escaping @Sendable () async -> DeviceToolOutcome) async -> DeviceToolOutcome {
        await withTaskGroup(of: DeviceToolOutcome?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: max(limit, .milliseconds(100)))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(.failed, "The device did not finish in time.")
        }
    }

    private func run(_ request: DeviceToolRequest, budget: Duration) async -> DeviceToolOutcome {
        guard let action = DeviceToolAction(rawValue: request.action) else {
            return .failure(.unsupported, "This device does not do \(request.action).")
        }
        guard action.connector.rawValue == request.connector else {
            return .failure(.invalidArgs, "\(request.action) does not belong to \(request.connector).")
        }
        let connector = action.connector
        if let refusal = await gate(connector, action: action, request: request) { return refusal }
        if let refusal = await osPermission(for: connector) { return refusal }
        do {
            return .success(try await dispatch(action, request.args, budget: budget))
        } catch DeviceProviderError.unsupported {
            return .failure(.unsupported, "This device cannot do \(action.rawValue).")
        } catch let error as DeviceProviderError {
            return Self.outcome(for: error)
        } catch is CancellationError {
            return .failure(.failed, "The request was cancelled.")
        } catch is DecodingError {
            return .failure(.invalidArgs, "The arguments for \(action.rawValue) could not be read.")
        } catch {
            return .failure(.failed, "This device could not complete \(action.rawValue).")
        }
    }

    private func gate(_ connector: DeviceConnectorID, action: DeviceToolAction, request: DeviceToolRequest) async -> DeviceToolOutcome? {
        var state = await ledger.state(for: connector)
        if state == nil || state == .off {
            _ = try? await ledger.refresh()
            state = await ledger.state(for: connector)
        }
        guard let state, state.isEnabled else {
            return .failure(.consentDeclined, "\(Self.title(connector)) is turned off on this device.")
        }
        guard request.needsConsent else { return nil }
        let granted = await consent.askConsent(ConsentAsk(connector: connector, action: action, profile: request.profile))
        guard granted else { return .failure(.consentDeclined, "You chose not to allow \(Self.title(connector)).") }
        _ = try? await ledger.set(connector, state: .allowed)
        return nil
    }

    private func osPermission(for connector: DeviceConnectorID) async -> DeviceToolOutcome? {
        guard connector.needsOSPermission else { return nil }
        var status = await permissions.status(of: connector)
        if status == .notDetermined, connector != .input { status = await permissions.request(connector) }
        await ledger.reportOSPermission(status, for: connector)
        switch status {
        case .granted: return nil
        case .unsupported: return .failure(.unsupported, "This device cannot use \(Self.title(connector)).")
        case .denied, .notDetermined:
            let place = connector == .input ? "System Settings > Privacy & Security > Accessibility" : "this device's Settings"
            return .failure(.permissionDenied, "Allow \(Self.title(connector)) for Pal in \(place).")
        }
    }

    static func title(_ connector: DeviceConnectorID) -> String {
        switch connector {
        case .calendar: "Calendar"
        case .home: "Home"
        case .reminders: "Reminders"
        case .contacts: "Contacts"
        case .location: "Location"
        case .alarms: "Alarms"
        case .shell: "Run commands"
        case .files: "Files"
        case .input: "Mouse and keyboard"
        case .apps: "Apps"
        }
    }

    static func outcome(for error: DeviceProviderError) -> DeviceToolOutcome {
        switch error {
        case .permissionDenied: .failure(.permissionDenied, "This device refused access.")
        case .accessDenied(let path): .failure(.permissionDenied, "Permission denied for \(path).")
        case .notFound: .failure(.notFound, "Nothing on this device matches that.")
        case .unsupported: .failure(.unsupported, "This device cannot do that.")
        case .invalidArgs(let message): .failure(.invalidArgs, message)
        case .failed(let message): .failure(.failed, message)
        }
    }
}

extension DeviceToolExecutor {
    private var zone: TimeZone { environment.timeZone() }

    private func date(_ text: String, _ field: String) throws -> Date {
        guard let parsed = ISODate.parse(text, defaultZone: zone) else {
            throw DeviceProviderError.invalidArgs("\(field) is not an ISO 8601 date.")
        }
        return parsed
    }

    private func iso(_ date: Date) -> String { ISODate.format(date, in: zone) }

    private func provider<T>(_ keyPath: KeyPath<DeviceProviders, T?>) throws -> T {
        guard let provider = providers[keyPath: keyPath] else { throw DeviceProviderError.unsupported }
        return provider
    }

    private func dispatch(_ action: DeviceToolAction, _ raw: JSONValue, budget: Duration) async throws -> JSONValue {
        switch action {
        case .calendarListEvents: try await listEvents(raw)
        case .calendarAddEvent: try await addEvent(raw)
        case .remindersList: try await listReminders(raw)
        case .remindersAdd: try await addReminder(raw)
        case .remindersComplete: try await completeReminder(raw)
        case .contactsSearch: try await searchContacts(raw)
        case .locationCurrent: try await currentLocation(raw)
        case .locationSearchNearby: try await searchNearby(raw)
        case .alarmsSet: try await setAlarm(raw)
        case .alarmsList: try await listAlarms()
        case .timersStart: try await startTimer(raw)
        case .homeListAccessories: try await listAccessories(raw)
        case .homeSet: try await setAccessory(raw)
        case .shellRun: try await runShell(raw, budget: budget)
        case .filesRead: try await readFile(raw)
        case .filesList: try await listFiles(raw)
        case .filesWrite: try await writeFile(raw)
        case .inputDisplays, .inputMove, .inputClick, .inputDrag, .inputScroll, .inputType, .inputKey:
            try await InputToolHandler.run(action, raw, provider: provider(\.input))
        case .appsList: try await listApps(raw)
        case .appsOpen: try await openApp(raw)
        case .appsQuit: try await quitApp(raw)
        case .windowsList: try await listWindows(raw)
        case .windowsFocus: try await focusWindow(raw)
        }
    }

    private static let shellReserve: Duration = .seconds(3)
    private static let maximumCommandLength = 8000

    private func runShell(_ raw: JSONValue, budget: Duration) async throws -> JSONValue {
        let args: ShellRunArgs = try DeviceWire.decodeArgs(raw)
        guard !args.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeviceProviderError.invalidArgs("command is required.")
        }
        guard args.command.count <= Self.maximumCommandLength else {
            throw DeviceProviderError.invalidArgs("command must be at most \(Self.maximumCommandLength) characters.")
        }
        let seconds = args.timeoutSeconds ?? 30
        guard (1...300).contains(seconds) else { throw DeviceProviderError.invalidArgs("timeout_seconds must be between 1 and 300.") }
        let cwd = try args.cwd.map { try DevicePath.resolve($0) }
        let timeout = max(min(Duration.seconds(seconds), budget - Self.shellReserve), .milliseconds(500))
        let record = try await provider(\.shell).run(command: args.command, workingDirectory: cwd, timeout: timeout, captureLimit: DeviceTextLimit.output)
        let out = TextCap.finish(record.stdout, limit: DeviceTextLimit.output)
        let err = TextCap.finish(record.stderr, limit: DeviceTextLimit.output)
        return try DeviceWire.encode(ShellRunWire(
            exitCode: record.exitCode, stdout: out.text, stderr: err.text, timedOut: record.timedOut, truncated: out.truncated || err.truncated
        ))
    }

    private func readFile(_ raw: JSONValue) async throws -> JSONValue {
        let args: FilesReadArgs = try DeviceWire.decodeArgs(raw)
        let path = try DevicePath.resolve(args.path)
        let record = try await provider(\.files).read(path: path, captureLimit: DeviceTextLimit.fileContent)
        let content = TextCap.finish(record.content, limit: DeviceTextLimit.fileContent)
        return try DeviceWire.encode(FileReadWire(path: record.path, content: content.text, sizeBytes: record.sizeBytes, truncated: content.truncated))
    }

    private func listFiles(_ raw: JSONValue) async throws -> JSONValue {
        let args: FilesListArgs = try DeviceWire.decodeArgs(raw)
        let path = try DevicePath.resolve(args.path)
        let limit = Self.clamp(args.limit, 200, 1...500)
        let record = try await provider(\.files).list(path: path, limit: limit)
        let entries = record.entries.prefix(limit).map {
            FileEntryWire(name: $0.name, kind: $0.kind.rawValue, sizeBytes: $0.sizeBytes, modifiedAt: $0.modified.map(iso))
        }
        return try DeviceWire.encode(FileListWire(path: record.path, entries: Array(entries), truncated: record.truncated || record.entries.count > limit))
    }

    private func writeFile(_ raw: JSONValue) async throws -> JSONValue {
        let args: FilesWriteArgs = try DeviceWire.decodeArgs(raw)
        let path = try DevicePath.resolve(args.path)
        let record = try await provider(\.files).write(path: path, content: args.content, append: args.append ?? false, createDirs: args.createDirs ?? false)
        return try DeviceWire.encode(FileWriteWire(path: record.path, bytesWritten: record.bytesWritten))
    }

    private static let maximumApps = 200
    private static let maximumWindows = 200

    private func appWire(_ app: AppRecord) -> AppWire {
        AppWire(name: app.name, bundleId: app.bundleID, pid: app.pid, frontmost: app.frontmost)
    }

    private func appName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw DeviceProviderError.invalidArgs("app must be an app name or bundle id of at most 200 characters.") }
        return name
    }

    private func listApps(_ raw: JSONValue) async throws -> JSONValue {
        let args: AppsListArgs = try DeviceWire.decodeArgs(raw)
        let limit = Self.clamp(args.limit, Self.maximumApps, 1...Self.maximumApps)
        let apps = try await provider(\.apps).apps()
        return try DeviceWire.encode(AppsListWire(apps: apps.prefix(limit).map(appWire), truncated: apps.count > limit))
    }

    private static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    private func openApp(_ raw: JSONValue) async throws -> JSONValue {
        let args: AppsOpenArgs = try DeviceWire.decodeArgs(raw)
        let name = try appName(args.app)
        let target = try args.target.map { text -> String in
            if let scheme = URL(string: text)?.scheme?.lowercased() {
                guard Self.openableSchemes.contains(scheme) else { throw DeviceProviderError.invalidArgs("target must be a web link, a mailto link, or a file path.") }
                return text
            }
            return try DevicePath.resolve(text)
        }
        let record = try await provider(\.apps).open(app: name, target: target)
        return try DeviceWire.encode(AppOpenWire(app: appWire(record.app), launched: record.launched))
    }

    private func quitApp(_ raw: JSONValue) async throws -> JSONValue {
        let args: AppsQuitArgs = try DeviceWire.decodeArgs(raw)
        let record = try await provider(\.apps).quit(app: appName(args.app))
        return try DeviceWire.encode(AppQuitWire(app: appWire(record), quitRequested: true))
    }

    private func listWindows(_ raw: JSONValue) async throws -> JSONValue {
        let args: WindowsListArgs = try DeviceWire.decodeArgs(raw)
        let limit = Self.clamp(args.limit, Self.maximumWindows, 1...Self.maximumWindows)
        let app = try args.app.map { try appName($0) }
        let record = try await provider(\.apps).windows(app: app, onScreenOnly: args.onScreenOnly ?? false)
        let windows = record.windows.prefix(limit).map {
            WindowWire(
                windowId: $0.id, app: $0.app, pid: $0.pid, title: record.titlesAvailable ? $0.title : nil,
                frame: WindowFrameWire(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height),
                onScreen: $0.onScreen
            )
        }
        let note = record.titlesAvailable ? nil : Self.titlesNote
        return try DeviceWire.encode(WindowsListWire(
            windows: Array(windows), titlesAvailable: record.titlesAvailable, truncated: record.windows.count > limit, note: note
        ))
    }

    static let titlesNote = "Window titles need Screen Recording permission for Pal (System Settings > Privacy & Security)."

    private func focusWindow(_ raw: JSONValue) async throws -> JSONValue {
        let args: WindowsFocusArgs = try DeviceWire.decodeArgs(raw)
        let app = try args.app.map { try appName($0) }
        guard args.windowId != nil || app != nil else { throw DeviceProviderError.invalidArgs("Pass window_id or app.") }
        let record = try await provider(\.apps).focus(windowID: args.windowId, app: app)
        return try DeviceWire.encode(WindowsFocusWire(app: appWire(record.app), windowId: record.windowID, raised: record.raised, note: record.note))
    }

    private func listEvents(_ raw: JSONValue) async throws -> JSONValue {
        let args: CalendarListEventsArgs = try DeviceWire.decodeArgs(raw)
        let start = try date(args.start, "start"), end = try date(args.end, "end")
        guard end > start else { throw DeviceProviderError.invalidArgs("end must be after start.") }
        let events = try await provider(\.calendar).events(from: start, to: end, limit: Self.clamp(args.limit, 50, 1...100))
        return try DeviceWire.encode(["events": events.map(wire)])
    }

    private func addEvent(_ raw: JSONValue) async throws -> JSONValue {
        let args: CalendarAddEventArgs = try DeviceWire.decodeArgs(raw)
        let title = args.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw DeviceProviderError.invalidArgs("title is required.") }
        let start = try date(args.start, "start")
        let end = try args.end.map { try date($0, "end") }
        if let end, end < start { throw DeviceProviderError.invalidArgs("end must not be before start.") }
        let draft = CalendarEventDraft(
            title: title, start: start, end: end, isAllDay: args.allDay ?? false, location: args.location,
            notes: args.notes, calendar: args.calendar, alertMinutesBefore: args.alertMinutesBefore
        )
        return try DeviceWire.encode(["event": wire(try await provider(\.calendar).add(draft))])
    }

    private func listReminders(_ raw: JSONValue) async throws -> JSONValue {
        let args: RemindersListArgs = try DeviceWire.decodeArgs(raw)
        let reminders = try await provider(\.reminders).list(
            named: args.list, includeCompleted: args.includeCompleted ?? false, limit: Self.clamp(args.limit, 50, 1...100)
        )
        return try DeviceWire.encode(["reminders": reminders.map(wire)])
    }

    private func addReminder(_ raw: JSONValue) async throws -> JSONValue {
        let args: RemindersAddArgs = try DeviceWire.decodeArgs(raw)
        let title = args.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw DeviceProviderError.invalidArgs("title is required.") }
        let priority = try args.priority.map { text -> ReminderPriority in
            guard let value = ReminderPriority(rawValue: text) else { throw DeviceProviderError.invalidArgs("priority must be none, low, medium or high.") }
            return value
        } ?? .none
        let draft = ReminderDraft(title: title, due: try args.due.map { try date($0, "due") }, notes: args.notes, list: args.list, priority: priority)
        return try DeviceWire.encode(["reminder": wire(try await provider(\.reminders).add(draft))])
    }

    private func completeReminder(_ raw: JSONValue) async throws -> JSONValue {
        let args: RemindersCompleteArgs = try DeviceWire.decodeArgs(raw)
        guard !args.reminderId.isEmpty else { throw DeviceProviderError.invalidArgs("reminder_id is required.") }
        return try DeviceWire.encode(["reminder": wire(try await provider(\.reminders).complete(id: args.reminderId))])
    }

    private func searchContacts(_ raw: JSONValue) async throws -> JSONValue {
        let args: ContactsSearchArgs = try DeviceWire.decodeArgs(raw)
        let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw DeviceProviderError.invalidArgs("query is required.") }
        let found = try await provider(\.contacts).search(query, limit: Self.clamp(args.limit, 10, 1...25))
        let contacts = found.map { ContactWire(id: $0.id, name: $0.name, organization: $0.organization, phones: Array($0.phones.prefix(5)), emails: Array($0.emails.prefix(5))) }
        return try DeviceWire.encode(["contacts": contacts])
    }

    private func currentLocation(_ raw: JSONValue) async throws -> JSONValue {
        let args: LocationCurrentArgs = try DeviceWire.decodeArgs(raw)
        let fix = try await provider(\.location).current(precise: args.accuracy == "precise")
        return try DeviceWire.encode(LocationWire(
            latitude: fix.latitude, longitude: fix.longitude, accuracyMeters: fix.accuracyMeters,
            place: fix.place, timestamp: fix.timestamp.map(iso)
        ))
    }

    private func searchNearby(_ raw: JSONValue) async throws -> JSONValue {
        let args: LocationSearchNearbyArgs = try DeviceWire.decodeArgs(raw)
        let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw DeviceProviderError.invalidArgs("query is required.") }
        let places = try await provider(\.location).searchNearby(
            query, radiusMeters: Self.clamp(args.radiusMeters, 2000, 100...50000), limit: Self.clamp(args.limit, 10, 1...25)
        )
        let wired = places.map {
            PlaceWire(name: $0.name, address: $0.address, latitude: $0.latitude, longitude: $0.longitude, distanceMeters: $0.distanceMeters, category: $0.category, phone: $0.phone)
        }
        return try DeviceWire.encode(["places": wired])
    }

    private func setAlarm(_ raw: JSONValue) async throws -> JSONValue {
        let args: AlarmsSetArgs = try DeviceWire.decodeArgs(raw)
        let weekdays = try (args.repeatWeekdays ?? []).map { text -> Weekday in
            guard let day = Weekday(rawValue: text) else { throw DeviceProviderError.invalidArgs("\(text) is not a weekday.") }
            return day
        }
        let alarm = try await provider(\.alarms).setAlarm(at: try date(args.at, "at"), label: args.label, repeatWeekdays: weekdays)
        return try DeviceWire.encode(["alarm": wire(alarm)])
    }

    private func listAlarms() async throws -> JSONValue {
        let alarms = try await provider(\.alarms).alarms()
        return try DeviceWire.encode(["alarms": alarms.prefix(50).map(wire)])
    }

    private func startTimer(_ raw: JSONValue) async throws -> JSONValue {
        let args: TimersStartArgs = try DeviceWire.decodeArgs(raw)
        guard (1...86400).contains(args.seconds) else { throw DeviceProviderError.invalidArgs("seconds must be between 1 and 86400.") }
        let timer = try await provider(\.alarms).startTimer(seconds: args.seconds, label: args.label)
        return try DeviceWire.encode(["timer": TimerWire(id: timer.id, label: timer.label, seconds: timer.seconds, endsAt: iso(timer.endsAt))])
    }

    private func listAccessories(_ raw: JSONValue) async throws -> JSONValue {
        let args: HomeListAccessoriesArgs = try DeviceWire.decodeArgs(raw)
        let accessories = try await provider(\.home).accessories(inRoom: args.room)
        return try DeviceWire.encode(["accessories": accessories.prefix(100).map(wire)])
    }

    private func setAccessory(_ raw: JSONValue) async throws -> JSONValue {
        let args: HomeSetArgs = try DeviceWire.decodeArgs(raw)
        guard let characteristic = HomeCharacteristic(rawValue: args.characteristic) else {
            throw DeviceProviderError.invalidArgs("characteristic must be power, brightness, lock or target_temperature.")
        }
        return try DeviceWire.encode(["accessory": wire(try await provider(\.home).set(accessoryID: args.accessoryId, characteristic: characteristic, value: args.value))])
    }

    static func clamp(_ value: Int?, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value ?? fallback, range.lowerBound), range.upperBound)
    }

    private func wire(_ event: CalendarEventRecord) -> CalendarEventWire {
        CalendarEventWire(
            id: event.id, title: event.title, start: iso(event.start), end: event.end.map(iso), allDay: event.isAllDay,
            location: event.location, calendar: event.calendar, notes: event.notes
        )
    }

    private func wire(_ reminder: ReminderRecord) -> ReminderWire {
        ReminderWire(
            id: reminder.id, title: reminder.title, due: reminder.due.map(iso), completed: reminder.isCompleted,
            list: reminder.list, notes: reminder.notes, priority: reminder.priority.rawValue
        )
    }

    private func wire(_ alarm: AlarmRecord) -> AlarmWire {
        AlarmWire(id: alarm.id, label: alarm.label, at: iso(alarm.at), enabled: alarm.isEnabled, repeatWeekdays: alarm.repeatWeekdays.map(\.rawValue))
    }

    private func wire(_ accessory: AccessoryRecord) -> AccessoryWire {
        AccessoryWire(id: accessory.id, name: accessory.name, room: accessory.room, category: accessory.category, reachable: accessory.isReachable, state: accessory.state)
    }
}
