import PalProtocol

public enum DeviceConnectorDefaults {
    public static func entry(for connector: DeviceConnectorID) -> (title: String, subtitle: String) {
        switch connector {
        case .calendar: ("Calendar", "See your day and add events")
        case .home: ("Home", "Control lights, locks and more")
        case .reminders: ("Reminders", "Set and check reminders")
        case .contacts: ("Contacts", "Look up people you know")
        case .location: ("Location", "Find places near you")
        case .alarms: ("Alarms", "Set alarms and timers")
        case .shell: ("Run commands", "Let bots run commands on this Mac")
        case .files: ("Files", "Let bots read and change files on this Mac")
        case .clipboard: ("Clipboard", "Let bots read and change this Mac's clipboard")
        case .apps: ("Apps", "Let bots open and switch apps on this Mac")
        }
    }

    public static func warning(for connector: DeviceConnectorID) -> String? {
        switch connector {
        case .shell: "A bot can then run commands on this Mac without asking each time."
        case .files: "A bot can then read and change files on this Mac without asking each time."
        case .clipboard: "The clipboard often holds passwords and private text. A bot can then read it and replace it without asking each time."
        case .apps: "A bot can then open and quit apps, bring windows to the front, and see which apps and window titles are open on this Mac without asking each time."
        case .calendar, .home, .reminders, .contacts, .location, .alarms: nil
        }
    }
}
