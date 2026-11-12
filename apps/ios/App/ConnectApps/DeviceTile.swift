import PalDesign
import PalProtocol
import SwiftUI

struct DeviceTile: View {
    let connector: DeviceConnectorID

    var body: some View {
        AppTile(style: .filled(color)) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var symbol: String {
        switch connector {
        case .calendar: "calendar"
        case .home: "house.fill"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle.fill"
        case .location: "location.fill"
        case .alarms: "alarm.fill"
        case .shell: "terminal.fill"
        case .files: "folder.fill"
        case .input: "cursorarrow.click.2"
        case .screen: "display"
        case .notifications: "bell.fill"
        case .apps: "macwindow"
        case .clipboard: "doc.on.clipboard.fill"
        case .messages: "message.fill"
        }
    }

    private var color: RGB {
        switch connector {
        case .calendar: RGB(hex: 0xe5493a)
        case .home: RGB(hex: 0xf58903)
        case .reminders: RGB(hex: 0x2d7cf6)
        case .contacts: RGB(hex: 0x8e8e93)
        case .location: RGB(hex: 0x1c65cb)
        case .alarms: RGB(hex: 0x2c2c2e)
        case .shell: RGB(hex: 0x3a3a3c)
        case .files: RGB(hex: 0x1c8ef0)
        case .input: RGB(hex: 0x6e4ccf)
        case .screen: RGB(hex: 0x6e4bd8)
        case .notifications: RGB(hex: 0xe5493a)
        case .apps: RGB(hex: 0x5e5ce6)
        case .clipboard: RGB(hex: 0x8e6bd8)
        case .messages: RGB(hex: 0x34c759)
        }
    }
}
