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
        case .shell, .files: ("This Mac", "Always available to your bots")
        case .input: ("Mouse and keyboard", "Let bots control this Mac's mouse and keyboard")
        case .screen: ("Screen", "Let bots see this Mac's screen")
        case .notifications: ("Notifications", "Let bots show notifications on this Mac")
        case .clipboard: ("Clipboard", "Let bots read and change this Mac's clipboard")
        case .apps: ("Apps", "Let bots open and switch apps on this Mac")
        }
    }

    public static func warning(for connector: DeviceConnectorID) -> String? {
        switch connector {
        case .input: "A bot can then click and type anywhere on this Mac without asking, including approving payments, sending messages and deleting files. Press Escape three times quickly, or choose Stop in the Pal menu bar item, to turn it off at once."
        case .screen: "A bot can then see everything on this Mac's screen, including passwords and private messages, without asking each time."
        case .notifications: "A bot can then show text on your screen at any time, which could be used to mislead you. Each one says which bot it is from."
        case .clipboard: "The clipboard often holds passwords and private text. A bot can then read it and replace it without asking each time."
        case .apps: "A bot can then open and quit apps, bring windows to the front, and see which apps and window titles are open on this Mac without asking each time."
        case .calendar, .home, .reminders, .contacts, .location, .alarms, .shell, .files: nil
        }
    }
}
