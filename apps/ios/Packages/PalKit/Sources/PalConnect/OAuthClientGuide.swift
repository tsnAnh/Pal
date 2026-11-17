import Foundation

public enum OAuthClientGuide {
    static let guidedSlugs: Set<String> = ["google-workspace"]

    public static func steps(slug: String, appName: String) -> [String] {
        switch slug {
        case "google-workspace":
            [
                String(localized: "Open Google Cloud Console, then go to APIs & Services > Credentials."),
                String(localized: "Choose Create credentials > OAuth client ID and set the type to Web application."),
                String(localized: "Add the address below as an Authorized redirect URI, exactly as shown."),
                String(localized: "Add yourself as a test user on the OAuth consent screen."),
                String(localized: "Copy the client ID and client secret into the fields below."),
            ]
        default:
            [
                String(localized: "Open the \(appName) developer console and create an OAuth client."),
                String(localized: "Set its redirect URL to exactly the address below."),
                String(localized: "Copy the client ID and client secret into the fields below."),
            ]
        }
    }

    public static func consoleTitle(slug: String, appName: String) -> String {
        switch slug {
        case "google-workspace": String(localized: "Open Google Cloud Console")
        default: String(localized: "Open \(appName) developer console")
        }
    }
}
