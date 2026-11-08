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
        }
    }
}
