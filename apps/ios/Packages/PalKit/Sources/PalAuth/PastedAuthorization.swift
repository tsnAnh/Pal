import Foundation

public enum PasteError: Error, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case empty
    case tooLong
    case malformed
    case wrongAddress
    case duplicateParameter
    case missingState
    case stateMismatch
    case missingCode
    case denied
    case failed

    public var description: String { userText }

    public var debugDescription: String { userText }

    public var userText: String {
        switch self {
        case .empty: return "Paste the address from your browser."
        case .tooLong: return "That is too long to be the sign-in address."
        case .malformed: return "That doesn't look like the address. Copy the whole address and paste it again."
        case .wrongAddress: return "That isn't the address this sign-in is waiting for. Copy the address of the page that failed to load."
        case .duplicateParameter: return "That address has repeated parts, so it can't be used. Copy it again."
        case .missingState, .missingCode: return "That address is missing part of the sign-in answer. Copy the whole address."
        case .stateMismatch: return "That address belongs to a different sign-in. Start again."
        case .denied: return "Access was not granted."
        case .failed: return "The sign-in service couldn't finish the sign-in. Start again."
        }
    }

    public var keepsAttemptOpen: Bool {
        switch self {
        case .empty, .tooLong, .malformed, .wrongAddress, .duplicateParameter, .missingState, .missingCode: return true
        case .stateMismatch, .denied, .failed: return false
        }
    }
}

public enum PastedAuthorization {
    public static let maxLength = 4096
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost"]
    private static let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",&"))
    private static let wrappers = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`<>\u{201C}\u{201D}\u{2018}\u{2019}"))

    public static func clean(_ text: String) -> String {
        return text.trimmingCharacters(in: wrappers)
    }

    public static func parse(_ text: String, expectedState: String, expectedRedirect: URL) -> Result<String, PasteError> {
        guard text.utf8.count <= maxLength else { return .failure(.tooLong) }
        let cleaned = clean(text)
        guard !cleaned.isEmpty else { return .failure(.empty) }
        let found = cleaned.contains("://") ? addressItems(cleaned, expectedRedirect: expectedRedirect) : labelledItems(cleaned)
        switch found {
        case .failure(let failure): return .failure(failure)
        case .success(let items): return resolve(items, expectedState: expectedState)
        }
    }

    private static func addressItems(_ text: String, expectedRedirect: URL) -> Result<[URLQueryItem], PasteError> {
        guard let components = URLComponents(string: text) else { return .failure(.malformed) }
        guard components.scheme?.lowercased() == "http", components.user == nil, components.password == nil,
              let host = components.host?.lowercased(), loopbackHosts.contains(host),
              components.path == expectedRedirect.path, components.port == expectedRedirect.port
        else { return .failure(.wrongAddress) }
        return .success(components.queryItems ?? [])
    }

    private static func labelledItems(_ text: String) -> Result<[URLQueryItem], PasteError> {
        let body = text.hasPrefix("?") ? String(text.dropFirst()) : text
        var items = [URLQueryItem]()
        for token in body.components(separatedBy: separators) where !token.isEmpty {
            guard let split = token.firstIndex(of: "=") else { return .failure(.malformed) }
            let name = String(token[..<split])
            guard !name.isEmpty, let value = String(token[token.index(after: split)...]).removingPercentEncoding else { return .failure(.malformed) }
            items.append(URLQueryItem(name: name, value: value))
        }
        return .success(items)
    }

    private static func resolve(_ items: [URLQueryItem], expectedState: String) -> Result<String, PasteError> {
        var states = [String]()
        var codes = [String]()
        var errors = [String]()
        for item in items {
            switch item.name {
            case "state": states.append(item.value ?? "")
            case "code": codes.append(item.value ?? "")
            case "error": errors.append(item.value ?? "")
            default: break
            }
        }
        guard states.count <= 1, codes.count <= 1, errors.count <= 1 else { return .failure(.duplicateParameter) }
        guard let state = states.first, !state.isEmpty else { return .failure(.missingState) }
        guard ConstantTime.equal(state, expectedState) else { return .failure(.stateMismatch) }
        if let error = errors.first { return .failure(error == "access_denied" ? .denied : .failed) }
        guard let code = codes.first, !code.isEmpty else { return .failure(.missingCode) }
        return .success(code)
    }
}

@MainActor
public protocol PasteboardAccess {
    var changeCount: Int { get }
    func clear()
}

@MainActor
public struct PasteboardScrub {
    private let pasteboard: any PasteboardAccess

    public init(_ pasteboard: any PasteboardAccess) {
        self.pasteboard = pasteboard
    }

    public func mark() -> Int {
        return pasteboard.changeCount
    }

    @discardableResult
    public func clear(ifUnchangedSince mark: Int) -> Bool {
        guard pasteboard.changeCount == mark else { return false }
        pasteboard.clear()
        return true
    }
}
