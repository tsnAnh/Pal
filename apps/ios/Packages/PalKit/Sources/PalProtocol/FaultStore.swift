import Foundation

public struct FaultRecord: Sendable, Hashable, Codable, Identifiable {
    public var code: Int?
    public var reason: String
    public var trace: String
    public var method: String
    public var source: String
    public var gatewayVersion: String?
    public var at: Date
    public var reported: Bool

    public var id: String { "\(trace)-\(at.timeIntervalSince1970)" }

    public init(_ fault: GatewayFault, at: Date) {
        code = fault.code
        reason = fault.reason
        trace = fault.trace.rawValue
        method = fault.method
        source = fault.source.rawValue
        gatewayVersion = fault.gatewayVersion
        self.at = at
        reported = false
    }

    public var reportable: Bool { source != GatewayFault.Source.gateway.rawValue && !reported }

    public var detailsLine: String {
        [reason, "trace \(trace)", gatewayVersion.map { "gateway \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }

    public func copyText(appVersion: String) -> String {
        "\(detailsLine)\napp: \(appVersion)"
    }

    public func line(appVersion: String) -> String {
        [
            at.formatted(.iso8601), reason, code.map { "code \($0)" }, method, "trace \(trace)", "source \(source)",
            gatewayVersion.map { "gateway \($0)" }, "app \(appVersion)",
        ].compactMap { $0 }.joined(separator: ", ")
    }

    public static func lines(_ records: [FaultRecord], appVersion: String) -> String {
        records.map { $0.line(appVersion: appVersion) }.joined(separator: "\n")
    }
}

public actor FaultStore {
    public static let capacity = 200
    public static let maxAge: TimeInterval = 7 * 24 * 3600
    public static let reportBatch = 20

    public static let shared = FaultStore(
        fileURL: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("pal-faults.json")
    )

    private let fileURL: URL
    private let now: @Sendable () -> Date
    private var loaded: [FaultRecord]?
    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(fileURL: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
    }

    public func record(_ fault: GatewayFault) {
        var current = pruned(entries())
        current.append(FaultRecord(fault, at: now()))
        save(Array(current.suffix(Self.capacity)))
    }

    public func records() -> [FaultRecord] {
        pruned(entries()).reversed()
    }

    public func pendingReports() -> [FaultRecord] {
        Array(pruned(entries()).filter(\.reportable).prefix(Self.reportBatch))
    }

    public func markReported(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        save(entries().map { record in
            var record = record
            if ids.contains(record.id) { record.reported = true }
            return record
        })
    }

    public func clear() {
        save([])
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        changeContinuations[key] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropListener(key) } }
        return stream
    }

    private func dropListener(_ key: UUID) {
        changeContinuations[key] = nil
    }

    private func pruned(_ entries: [FaultRecord]) -> [FaultRecord] {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        return entries.filter { $0.at >= cutoff }
    }

    private func entries() -> [FaultRecord] {
        if let loaded { return loaded }
        let decoded = (try? Data(contentsOf: fileURL)).flatMap { try? Self.decoder.decode([FaultRecord].self, from: $0) } ?? []
        loaded = decoded
        return decoded
    }

    private func save(_ entries: [FaultRecord]) {
        loaded = entries
        if let data = try? Self.encoder.encode(entries) {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: [.atomic])
        }
        for continuation in changeContinuations.values { continuation.yield() }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
