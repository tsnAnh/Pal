import Foundation
import PalDiagnostics
import PalProtocol

public enum SetupDevice: String, Sendable, Equatable, Codable {
    case mac
    case iphone
    case ipad

    public init(platform: ConnectorPlatform) {
        switch platform {
        case .mac: self = .mac
        case .iPhone: self = .iphone
        case .iPad: self = .ipad
        }
    }

    public var name: String {
        switch self {
        case .mac: String(localized: "Mac")
        case .iphone: String(localized: "iPhone")
        case .ipad: String(localized: "iPad")
        }
    }

    @MainActor
    public static var current: SetupDevice { SetupDevice(platform: ConnectorPlatform.current) }
}

public struct SetupProgressRecord: Decodable, Sendable, Equatable {
    public var connector: String
    public var bot: String?
    public var stepID: String
    public var completed: [String]
    public var device: SetupDevice?
    public var updatedAt: Double

    public init(
        connector: String, bot: String? = nil, stepID: String, completed: [String] = [], device: SetupDevice? = nil, updatedAt: Double = 0
    ) {
        self.connector = connector
        self.bot = bot
        self.stepID = stepID
        self.completed = completed
        self.device = device
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case connector, bot, completed, device
        case stepID = "step_id"
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connector = try container.decode(String.self, forKey: .connector)
        bot = try container.decodeIfPresent(String.self, forKey: .bot)
        stepID = try container.decode(String.self, forKey: .stepID)
        completed = try container.decodeIfPresent([String].self, forKey: .completed) ?? []
        device = try? container.decodeIfPresent(SetupDevice.self, forKey: .device)
        updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
    }
}

extension ConnectAppsService {
    public func setupProgress(connector: String? = nil) async throws -> [SetupProgressRecord] {
        var params: [String: JSONValue] = [:]
        if let connector { params["connector"] = .string(connector) }
        return try decodeList(await call("connectors.setup.progress.get", params), key: "records", as: SetupProgressRecord.self)
    }

    public func saveSetupProgress(connector: String, stepID: String, completed: [String], device: SetupDevice, finished: Bool = false) async throws {
        _ = try await call(
            "connectors.setup.progress.set",
            [
                "connector": .string(connector), "step_id": .string(stepID), "completed": .array(completed.map(JSONValue.string)),
                "device": .string(device.rawValue), "finished": .bool(finished),
            ]
        )
    }
}

public struct GatewayStepFlowProgressStore: StepFlowProgressStore {
    private let service: ConnectAppsService
    private let device: SetupDevice
    private let gatewaySaved: Set<String>?

    public init(service: ConnectAppsService, device: SetupDevice, gatewaySaved: [String]? = nil) {
        self.service = service
        self.device = device
        self.gatewaySaved = gatewaySaved.map(Set.init)
    }

    public func load(flowID: String) async -> StepFlowProgress? {
        do {
            let records = try await service.setupProgress(connector: flowID)
            guard let record = records.first(where: { $0.connector == flowID && $0.bot == nil }) else { return nil }
            if let gatewaySaved, !Set(record.completed).isSubset(of: gatewaySaved) { return nil }
            return StepFlowProgress(
                flowID: flowID, stepID: record.stepID, saved: record.completed,
                continuedFrom: record.device == device ? nil : record.device
            )
        } catch {
            report("read", error)
            return nil
        }
    }

    public func save(_ progress: StepFlowProgress) async {
        do {
            try await service.saveSetupProgress(connector: progress.flowID, stepID: progress.stepID, completed: progress.saved, device: device)
        } catch {
            report("save", error)
        }
    }

    public func clear(flowID: String) async {
        do {
            try await service.saveSetupProgress(connector: flowID, stepID: "done", completed: [], device: device, finished: true)
        } catch {
            report("clear", error)
        }
    }

    private func report(_ action: String, _ error: any Error) {
        service.diagnostics.info("connect", "setup progress \(action) failed: \(Diagnostics.describe(error))")
    }
}

public struct SetupContinuation: Sendable, Equatable {
    public var device: SetupDevice
    public var stepID: String
    public var doneSteps: Int

    public init?(device: SetupDevice?, stepID: String, doneSteps: Int) {
        guard let device, doneSteps > 0 else { return nil }
        self.device = device
        self.stepID = stepID
        self.doneSteps = doneSteps
    }

    public var title: String { String(localized: "Continued from your \(device.name)") }

    public var detail: String {
        switch doneSteps {
        case 1: String(localized: "Step 1 is already done")
        case 2: String(localized: "Steps 1 and 2 are already done")
        default: String(localized: "Steps 1 to \(doneSteps) are already done")
        }
    }
}

public struct SetupResumeOffer: Sendable, Equatable, Identifiable {
    public var appID: String
    public var appName: String
    public var device: SetupDevice

    public init(appID: String, appName: String, device: SetupDevice) {
        self.appID = appID
        self.appName = appName
        self.device = device
    }

    public var id: String { appID }

    public var title: String { String(localized: "Continue \(appName)") }

    public var detail: String { String(localized: "Started on your \(device.name)") }
}

extension PalCatalogEntry {
    public var setupFlowID: String? {
        if method == .botTokenStdio { return DiscordFlow.flowID }
        return method == .oauthClient || setupGuide != nil ? OwnerSetupFlow.flowID(slug: slug) : nil
    }
}

public enum SetupResume {
    private static func flowID(for app: ConnectApp) -> String? {
        app.isGoogleAds ? GoogleAdsFlow.flowID : (app.oauthClientEntry ?? app.setupGuideEntry)?.setupFlowID
    }

    public static func offer(records: [SetupProgressRecord], apps: [ConnectApp], on device: SetupDevice) -> SetupResumeOffer? {
        let byFlow = Dictionary(apps.compactMap { app in flowID(for: app).map { ($0, app) } }, uniquingKeysWith: { first, _ in first })
        for record in records.sorted(by: { $0.updatedAt > $1.updatedAt }) where record.bot == nil {
            guard let from = record.device, from != device, let app = byFlow[record.connector], !app.isConnected else { continue }
            return SetupResumeOffer(appID: app.id, appName: app.name, device: from)
        }
        return nil
    }
}
