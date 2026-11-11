import HermesProtocol

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
        case .browser: ("Browser", "Let bots use your browser on this Mac")
        }
    }

    public static func warning(for connector: DeviceConnectorID) -> String? {
        switch connector {
        case .shell: "A bot can then run commands on this Mac without asking each time."
        case .files: "A bot can then read and change files on this Mac without asking each time."
        case .browser: "A bot can then drive a browser on this Mac, with the sites you are already signed in to, without asking each time. It never sees your passwords and only works in the window it opens."
        case .calendar, .home, .reminders, .contacts, .location, .alarms: nil
        }
    }
}
