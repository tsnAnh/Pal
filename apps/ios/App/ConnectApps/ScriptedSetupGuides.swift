import PalProtocol

enum ScriptedSetupGuides {
    static func progress(_ step: String, saved: [String]) -> JSONValue {
        ["step_id": .string(step), "saved": .array(saved.map(JSONValue.string))]
    }

    private static func link(_ label: String, _ url: String) -> JSONValue {
        ["label": .string(label), "url": .string(url)]
    }

    private static func field(_ id: String, _ label: String, secret: Bool, prefixes: [String] = [], suffix: String? = nil) -> JSONValue {
        [
            "id": .string(id), "label": .string(label), "secret": .bool(secret), "prefixes": .array(prefixes.map(JSONValue.string)),
            "suffix": suffix.map(JSONValue.string) ?? JSONValue.null,
        ]
    }

    private static func step(
        _ id: String, _ kind: String, _ title: String, body: String, links: [JSONValue] = [], copies: [JSONValue] = [],
        fields: [JSONValue] = [], check: String? = nil, problem: (String, String)? = nil, fallback: JSONValue = .null
    ) -> JSONValue {
        [
            "id": .string(id), "kind": .string(kind), "title": .string(title), "body": .string(body), "links": .array(links),
            "copies": .array(copies), "fields": .array(fields), "check": check.map(JSONValue.string) ?? JSONValue.null,
            "problem": problem.map { JSONValue.string($0.0) } ?? JSONValue.null,
            "problem_host": problem.map { JSONValue.string($0.1) } ?? JSONValue.null, "fallback": fallback,
        ]
    }

    static let ipAddressProblem = ("ip_host", "100.101.102.103")

    private static let googleFallback: JSONValue = [
        "label": "Google rejected the address",
        "body": "Use your own domain for your Pal's address, or create a Desktop app client, which needs no public address.",
        "links": [link("Google's Desktop app guide", "https://developers.google.com/identity/protocols/oauth2/native-app")],
    ]

    private static let googleServices = [
        ("Gmail", "gmail.googleapis.com"), ("Calendar", "calendar-json.googleapis.com"), ("Drive", "drive.googleapis.com"),
        ("People", "people.googleapis.com"), ("Sheets", "sheets.googleapis.com"), ("Docs", "docs.googleapis.com"),
    ]

    static func google(addressProblem: Bool, redirect: String) -> JSONValue {
        [
            "steps": [
                step(
                    "address", "public_url", "Your Pal's web address", body: "Google sends you back to your Pal after you sign in.",
                    problem: addressProblem ? ipAddressProblem : nil
                ),
                step(
                    "console", "open_page", "Create a Google sign-in client", body: "Create an OAuth client ID of type Web application.",
                    links: [link("Open Google Cloud credentials", "https://console.cloud.google.com/apis/credentials")],
                    copies: [["label": "Redirect URI", "value": .string(redirect)]], fallback: googleFallback
                ),
                step(
                    "apis", "open_page", "Turn on the Google services", body: "Turn on each service, then add yourself as a test user.",
                    links: googleServices.map { link($0.0, "https://console.cloud.google.com/apis/library/\($0.1)") }
                ),
                step(
                    "client", "paste", "Paste your client", body: "Paste the client ID and secret Google shows.",
                    fields: [
                        field("client_id", "Client ID", secret: false, suffix: ".apps.googleusercontent.com"),
                        field("client_secret", "Client secret", secret: true),
                    ],
                    check: "google_client"
                ),
            ],
        ]
    }

    static let github: JSONValue = [
        "steps": [
            step(
                "token_page", "open_page", "Create a GitHub token", body: "Create a fine-grained token with the permissions listed on the page.",
                links: [link("Open GitHub token page", "https://github.com/settings/personal-access-tokens/new")],
                copies: [["label": "Token name", "value": "Pal"]]
            ),
            step(
                "token", "paste", "Paste your token", body: "Paste the token GitHub shows once.",
                fields: [field("token", "Token", secret: true, prefixes: ["github_pat_", "ghp_"])], check: "github_token"
            ),
        ],
    ]

    private static let clientFields = [
        field("client_id", "Client ID", secret: false), field("client_secret", "Client secret", secret: true),
    ]

    static func figma(publicAddress: Bool) -> JSONValue {
        [
            "steps": [
                step(
                    "app", "open_page", "Create a Figma app", body: "Create a new app, then copy the Client ID and Client secret right away.",
                    links: [link("Open Figma apps", "https://www.figma.com/developers/apps")],
                    copies: mcpCopies(publicAddress, redirect: "Redirect URL", scopes: "current_user:read file_content:read")
                ),
                step("client", "paste", "Paste your client", body: "Paste the Client ID and Client secret Figma showed you.", fields: clientFields),
            ],
        ]
    }

    static func dropbox(publicAddress: Bool) -> JSONValue {
        [
            "steps": [
                step(
                    "app", "open_page", "Create a Dropbox app", body: "Create an app, add the redirect URI and tick the scopes.",
                    links: [link("Open Dropbox App Console", "https://www.dropbox.com/developers/console/apps")],
                    copies: mcpCopies(publicAddress, redirect: "Redirect URI", scopes: "account_info.read files.metadata.read")
                ),
                step(
                    "client", "paste", "Paste your app key and secret", body: "Paste the App key and App secret from the Settings tab.",
                    fields: [field("client_id", "App key", secret: false), field("client_secret", "App secret", secret: true)]
                ),
            ],
        ]
    }

    static func canva(publicAddress: Bool) -> JSONValue {
        [
            "steps": [
                step(
                    "app", "open_page", "Create a Canva app", body: "Create an app, then copy the Client ID and generate a secret right away.",
                    links: [link("Open Canva developer portal", "https://www.canva.com/developers/apps")],
                    copies: mcpCopies(publicAddress, redirect: "Redirect URL", scopes: "design:content:read profile:read")
                ),
                step(
                    "client", "paste", "Paste your client", body: "Paste the Client ID and secret Canva showed you.",
                    fields: clientFields, check: "canva_client"
                ),
            ],
        ]
    }

    private static func mcpCopies(_ publicAddress: Bool, redirect: String, scopes: String) -> [JSONValue] {
        let address: [JSONValue] = publicAddress
            ? [["label": .string(redirect), "value": .string(OAuthClientScript.mcpRedirect)]] : []
        return address + [["label": "Scopes", "value": .string(scopes)]]
    }
}
