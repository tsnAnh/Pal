import Foundation
import Observation
import SwiftUI

public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case followSystem
    case light
    case dark
    case black

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .followSystem: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        case .black: "Black"
        }
    }

    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .followSystem: nil
        case .light: .light
        case .dark, .black: .dark
        }
    }

    public func palette(systemScheme: ColorScheme) -> PalPalette {
        switch self {
        case .followSystem: systemScheme == .dark ? .measuredDark : .derivedLight
        case .light: .derivedLight
        case .dark: .measuredDark
        case .black: .derivedBlack
        }
    }
}

@MainActor
@Observable
public final class AppearanceStore {
    public static let defaultsKey = "hermesAppearanceMode"

    public var mode: AppearanceMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Self.defaultsKey)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.defaultsKey).flatMap(AppearanceMode.init(rawValue:)) ?? .followSystem
    }
}
