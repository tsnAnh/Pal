import Foundation

public struct SetupConfirmItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String

    public init(id: String, title: String, subtitle: String = "") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

public struct SetupConfirmation: Sendable, Equatable {
    public var title: String
    public var message: String
    public var confirmTitle: String

    public init(title: String, message: String, confirmTitle: String) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
    }
}

public struct SetupSwitch: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var subtitleWhenOff: String?
    public var isOn: Bool
    public var confirmTurningOff: SetupConfirmation?
    public var showsInitial: Bool

    public init(
        id: String, title: String, subtitle: String = "", subtitleWhenOff: String? = nil, isOn: Bool = false,
        confirmTurningOff: SetupConfirmation? = nil, showsInitial: Bool = false
    ) {
        self.showsInitial = showsInitial
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.subtitleWhenOff = subtitleWhenOff
        self.isOn = isOn
        self.confirmTurningOff = confirmTurningOff
    }
}

public struct SetupSwitchGroup: Sendable, Equatable, Identifiable {
    public var id: String
    public var header: String?
    public var switches: [SetupSwitch]
    public var needsOneOn: Bool
    public var emptyNote: String?
    public var exclusive: Bool

    public init(
        id: String, header: String? = nil, switches: [SetupSwitch], needsOneOn: Bool = false, emptyNote: String? = nil, exclusive: Bool = false
    ) {
        self.exclusive = exclusive
        self.id = id
        self.header = header
        self.switches = switches
        self.needsOneOn = needsOneOn
        self.emptyNote = emptyNote
    }
}

public struct SetupOpenAndCheck: Sendable, Equatable {
    public var link: SetupLink
    public var copies: [SetupCopy]
    public var recheckTitle: String
    public var waitingTitle: String
    public var waitingBody: String

    public init(link: SetupLink, copies: [SetupCopy] = [], recheckTitle: String, waitingTitle: String, waitingBody: String) {
        self.link = link
        self.copies = copies
        self.recheckTitle = recheckTitle
        self.waitingTitle = waitingTitle
        self.waitingBody = waitingBody
    }
}
