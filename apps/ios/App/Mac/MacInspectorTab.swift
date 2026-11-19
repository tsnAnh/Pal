#if os(macOS)
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case activity
    case library

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .activity: "Activity"
        case .library: "Library"
        }
    }
}
#endif
