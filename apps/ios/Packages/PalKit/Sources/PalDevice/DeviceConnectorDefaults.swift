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
        case .input: ("Mouse and keyboard", "Let bots control this Mac's mouse and keyboard")
        }
    }

    public static func warning(for connector: DeviceConnectorID) -> String? {
        switch connector {
        case .shell: "A bot can then run commands on this Mac without asking each time."
        case .files: "A bot can then read and change files on this Mac without asking each time."
        case .input: "A bot can then click and type anywhere on this Mac without asking, including approving payments, sending messages and deleting files. Press Escape three times quickly, or choose Stop in the Pal menu bar item, to turn it off at once."
        case .calendar, .home, .reminders, .contacts, .location, .alarms: nil
        }
    }
}
