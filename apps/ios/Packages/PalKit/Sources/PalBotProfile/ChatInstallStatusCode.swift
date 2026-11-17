import Foundation

extension ChatInstallModel {
    public static let gatewayOutdatedCode = "gateway_outdated"

    public var isStatusScreen: Bool {
        switch screen {
        case .unavailable, .unsupported, .error: true
        default: false
        }
    }

    public var statusCode: String? {
        switch screen {
        case .unavailable: (loadFailure ?? .gateway).rawValue
        case .unsupported: Self.gatewayOutdatedCode
        case .error(let code, _): code.rawValue
        default: nil
        }
    }
}
