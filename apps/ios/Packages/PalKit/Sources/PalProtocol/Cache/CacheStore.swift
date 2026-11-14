import CryptoKit
import Foundation
import PalDiagnostics

public final class CacheStore: Sendable {
    public static let formatVersion = 1
    public static let defaultMaxFileBytes = 6_000_000

    public let root: URL
    private let maxFileBytes: Int
    private let diagnostics: Diagnostics
    private let queue = DispatchQueue(label: "dev.tsnanh.hermes.cache", qos: .utility)

    private struct Envelope<Payload: Codable>: Codable {
        var version: Int
        var payload: Payload
    }

    public init(root: URL, maxFileBytes: Int = CacheStore.defaultMaxFileBytes, diagnostics: Diagnostics = .silent) {
        self.root = root
        self.maxFileBytes = maxFileBytes
        self.diagnostics = diagnostics
    }

    public static func standard(diagnostics: Diagnostics = .silent) -> CacheStore {
        CacheStore(
            root: URL.applicationSupportDirectory.appending(path: "cache", directoryHint: .isDirectory),
            diagnostics: diagnostics
        )
    }

    public static func accountDigest(_ account: String) -> String {
        SHA256.hash(data: Data(account.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public func load<Value: Codable & Sendable>(_ type: Value.Type, name: String, account: String) -> Value? {
        queue.sync { read(type, name: name, account: account) }
    }

    private func read<Value: Codable & Sendable>(_ type: Value.Type, name: String, account: String) -> Value? {
        let url = fileURL(name: name, account: account)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        guard let size = attributes[.size] as? Int, size <= maxFileBytes else {
            discard(url, reason: "oversized")
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: data),
              envelope.version == Self.formatVersion
        else {
            discard(url, reason: "unreadable")
            return nil
        }
        return envelope.payload
    }

    public func loadDetached<Value: Codable & Sendable>(_ type: Value.Type, name: String, account: String) async -> Value? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: read(type, name: name, account: account))
            }
        }
    }

    public func save<Value: Codable & Sendable>(_ value: Value, name: String, account: String) {
        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(Envelope(version: Self.formatVersion, payload: value)) else { return }
            guard data.count <= maxFileBytes else {
                diagnostics.info("cache", "skipped \(name): \(data.count) bytes exceeds the bound")
                return
            }
            let directory = accountDirectory(account)
            do {
                try prepare(directory)
                try data.write(to: fileURL(name: name, account: account), options: writeOptions)
            } catch {
                diagnostics.warning("cache", "write failed: \(Diagnostics.describe(error))")
            }
        }
    }

    public func remove(name: String, account: String) {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: fileURL(name: name, account: account))
        }
    }

    public func removeAll() {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: root)
        }
    }

    public func removeAll(except account: String) {
        queue.async { [self] in
            let keep = Self.accountDigest(account)
            let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where entry.lastPathComponent != keep {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    public func prune(account: String, prefix: String, keeping names: Set<String>) {
        queue.async { [self] in
            let directory = accountDirectory(account)
            let keep = Set(names.map(Self.fileName(for:)))
            let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            let marker = Self.encoded(prefix)
            for entry in entries where entry.lastPathComponent.hasPrefix(marker) && !keep.contains(entry.lastPathComponent) {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    public func drain() {
        queue.sync {}
    }

    static func fileName(for name: String) -> String {
        encoded(name) + ".json"
    }

    private static func encoded(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return encoded.isEmpty ? "_" : encoded
    }

    private func accountDirectory(_ account: String) -> URL {
        root.appending(path: Self.accountDigest(account), directoryHint: .isDirectory)
    }

    public func fileURL(name: String, account: String) -> URL {
        accountDirectory(account).appending(path: Self.fileName(for: name), directoryHint: .notDirectory)
    }

    private var writeOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }

    private func prepare(_ directory: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: root.path) {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableRoot = root
            try? mutableRoot.setResourceValues(values)
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func discard(_ url: URL, reason: String) {
        diagnostics.info("cache", "discarded \(reason) file")
        try? FileManager.default.removeItem(at: url)
    }
}
