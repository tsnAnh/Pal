import Foundation

public enum InstallStep: Int, CaseIterable, Sendable, Comparable {
    case download
    case preparePython
    case installComponents
    case setUp
    case startPal

    public static func < (lhs: InstallStep, rhs: InstallStep) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .download: String(localized: "Download Pal")
        case .preparePython: String(localized: "Prepare Python")
        case .installComponents: String(localized: "Install components")
        case .setUp: String(localized: "Set up")
        case .startPal: String(localized: "Start Pal")
        }
    }

    static let stageSteps: [String: InstallStep] = [
        "prerequisites": .download,
        "repository": .download,
        "venv": .preparePython,
        "python-deps": .installComponents,
        "products": .installComponents,
        "config": .setUp,
        "setup": .setUp,
        "gateway": .setUp,
        "complete": .setUp,
    ]

    public static func step(forStage name: String) -> InstallStep? { stageSteps[name] }
}

public struct InstallStage: Sendable, Equatable {
    public let name: String
    public let step: InstallStep

    public init(name: String, step: InstallStep) {
        self.name = name
        self.step = step
    }
}

public enum InstallManifestError: Error, Sendable, Equatable {
    case unreadable
    case unsupportedProtocol(Int)
    case empty
    case duplicateStage(String)
}

private struct InstallManifestEntry: Decodable {
    let name: String
}

private struct InstallManifestWire: Decodable {
    let protocolVersion: Int
    let stages: [InstallManifestEntry]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case stages
    }
}

public struct InstallManifest: Sendable, Equatable {
    public static let supportedProtocol = 1

    public let stages: [InstallStage]

    public init(stages: [InstallStage]) {
        self.stages = stages
    }

    public static func parse(_ data: Data) throws(InstallManifestError) -> InstallManifest {
        guard let wire = try? JSONDecoder().decode(InstallManifestWire.self, from: data) else { throw .unreadable }
        guard wire.protocolVersion == supportedProtocol else { throw .unsupportedProtocol(wire.protocolVersion) }
        guard !wire.stages.isEmpty else { throw .empty }
        var seen: Set<String> = []
        var stages: [InstallStage] = []
        for entry in wire.stages {
            guard seen.insert(entry.name).inserted else { throw .duplicateStage(entry.name) }
            let step = InstallStep.step(forStage: entry.name) ?? stages.last?.step ?? .download
            stages.append(InstallStage(name: entry.name, step: step))
        }
        return InstallManifest(stages: stages)
    }

    public func stages(from name: String?) -> [InstallStage] {
        guard let name, let index = stages.firstIndex(where: { $0.name == name }) else { return stages }
        return Array(stages[index...])
    }
}

public struct StageReport: Sendable, Equatable {
    public let ok: Bool
    public let stage: String
    public let skipped: Bool
    public let reason: String?

    public init(ok: Bool, stage: String, skipped: Bool, reason: String?) {
        self.ok = ok
        self.stage = stage
        self.skipped = skipped
        self.reason = reason
    }

    private struct Wire: Decodable {
        let ok: Bool
        let stage: String
        let skipped: Bool?
        let reason: String?
    }

    public static func parse(line: String) -> StageReport? {
        guard line.hasPrefix("{"), line.contains("\"ok\""), let data = line.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data)
        else { return nil }
        return StageReport(ok: wire.ok, stage: wire.stage, skipped: wire.skipped ?? false, reason: wire.reason)
    }
}

public struct OutputLineSplitter: Sendable {
    public static let maxLineBytes = 8 * 1024

    private var pending: [UInt8] = []

    public init() {}

    public mutating func feed(_ chunk: [UInt8]) -> [String] {
        var lines: [String] = []
        for byte in chunk {
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                if let line = flushLine() { lines.append(line) }
            } else if pending.count < Self.maxLineBytes {
                pending.append(byte)
            }
        }
        return lines
    }

    public mutating func finish() -> String? { flushLine() }

    private mutating func flushLine() -> String? {
        defer { pending.removeAll(keepingCapacity: true) }
        guard !pending.isEmpty else { return nil }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: pending, as: UTF8.self)
    }
}
