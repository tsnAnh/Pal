import Foundation

private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    fileprivate func lossyArray<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> [Value] {
        (try? decodeIfPresent([Lossy<Value>].self, forKey: key))?.compactMap(\.value) ?? []
    }
}

public struct SetupLink: Decodable, Sendable, Hashable {
    public var label: String
    public var url: URL

    public init(label: String, url: URL) {
        self.label = label
        self.url = url
    }

    enum CodingKeys: String, CodingKey { case label, url }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        let text = try container.decode(String.self, forKey: .url)
        guard let parsed = URL(string: text), let scheme = parsed.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "Not a web address")
        }
        url = parsed
    }
}

public struct SetupCopy: Decodable, Sendable, Hashable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct SetupField: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var secret: Bool
    public var prefixes: [String]
    public var suffix: String?

    public init(id: String, label: String, secret: Bool = false, prefixes: [String] = [], suffix: String? = nil) {
        self.id = id
        self.label = label
        self.secret = secret
        self.prefixes = prefixes
        self.suffix = suffix
    }

    enum CodingKeys: String, CodingKey { case id, label, secret, prefixes, suffix }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        secret = try container.decodeIfPresent(Bool.self, forKey: .secret) ?? false
        prefixes = try container.decodeIfPresent([String].self, forKey: .prefixes) ?? []
        suffix = try container.decodeIfPresent(String.self, forKey: .suffix).flatMap { $0.isEmpty ? nil : $0 }
    }
}

public enum SetupFieldShape: Sendable, Equatable {
    case empty
    case valid
    case hasSpaces
    case wrongStart([String])
    case wrongEnd(String)

    public var isValid: Bool { self == .valid }

    public var hint: String? {
        switch self {
        case .empty, .valid: nil
        case .hasSpaces: String(localized: "Remove the spaces.")
        case .wrongStart(let prefixes): String(localized: "Should start with \(prefixes.joined(separator: String(localized: " or ")))")
        case .wrongEnd(let suffix): String(localized: "Should end with \(suffix)")
        }
    }
}

extension SetupField {
    public func shape(of raw: String) -> SetupFieldShape {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .empty }
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return .hasSpaces }
        if !prefixes.isEmpty, !prefixes.contains(where: { value.hasPrefix($0) }) { return .wrongStart(prefixes) }
        if let suffix, !value.hasSuffix(suffix) { return .wrongEnd(suffix) }
        return .valid
    }
}

public struct SetupStep: Decodable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Decodable, Sendable {
        case publicURL = "public_url"
        case openPage = "open_page"
        case paste
    }

    public enum Check: String, Decodable, Sendable {
        case googleClient = "google_client"
        case githubToken = "github_token"
        case slackClient = "slack_client"
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var body: String
    public var links: [SetupLink]
    public var copies: [SetupCopy]
    public var fields: [SetupField]
    public var check: Check?

    public init(
        id: String, kind: Kind, title: String, body: String = "", links: [SetupLink] = [], copies: [SetupCopy] = [],
        fields: [SetupField] = [], check: Check? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.links = links
        self.copies = copies
        self.fields = fields
        self.check = check
    }

    enum CodingKeys: String, CodingKey { case id, kind, title, body, links, copies, fields, check }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        links = container.lossyArray(SetupLink.self, forKey: .links)
        copies = container.lossyArray(SetupCopy.self, forKey: .copies)
        fields = container.lossyArray(SetupField.self, forKey: .fields)
        check = try? container.decodeIfPresent(Check.self, forKey: .check)
    }
}

public struct SetupGuide: Decodable, Sendable, Hashable {
    public var steps: [SetupStep]

    public init(steps: [SetupStep]) {
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey { case steps }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        steps = try container.decode([SetupStep].self, forKey: .steps)
        guard !steps.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .steps, in: container, debugDescription: "A guide needs steps")
        }
    }

    public func index(of stepID: String?) -> Int {
        stepID.flatMap { id in steps.firstIndex { $0.id == id } } ?? 0
    }

    public var needsPublicAddress: Bool { steps.contains { $0.kind == .publicURL } }
}

public struct SetupProgress: Decodable, Sendable, Hashable {
    public var stepID: String
    public var saved: [String]

    public init(stepID: String, saved: [String] = []) {
        self.stepID = stepID
        self.saved = saved
    }

    enum CodingKeys: String, CodingKey {
        case stepID = "step_id"
        case saved
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stepID = try container.decode(String.self, forKey: .stepID)
        saved = try container.decodeIfPresent([String].self, forKey: .saved) ?? []
    }
}
