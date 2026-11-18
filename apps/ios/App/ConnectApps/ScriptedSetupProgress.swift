import Foundation
import PalProtocol

struct ScriptedSetupProgress {
    static let seedArgument = "-hermes-test-setup-progress-other-device"
    static let seededFlow = "owner-setup-google-workspace"

    private var records: [String: [String: JSONValue]] = [:]

    init(seeded: Bool) {
        guard seeded else { return }
        #if os(macOS)
        let other = "iphone"
        #else
        let other = "mac"
        #endif
        records[Self.seededFlow] = Self.row(connector: Self.seededFlow, step: "client", completed: [], device: other, at: 1)
    }

    mutating func handle(_ method: String, _ params: JSONValue) -> JSONValue {
        if method == "connectors.setup.progress.get" {
            let wanted = params["connector"]?.stringValue
            let rows = records.values.filter { wanted == nil || $0["connector"]?.stringValue == wanted }
            return ["records": .array(rows.map(JSONValue.object))]
        }
        let connector = params["connector"]?.stringValue ?? ""
        if params["finished"]?.boolValue == true {
            records[connector] = nil
            return ["record": .null]
        }
        let completed = (params["completed"]?.arrayValue ?? []).compactMap(\.stringValue)
        let row = Self.row(
            connector: connector, step: params["step_id"]?.stringValue ?? "", completed: completed,
            device: params["device"]?.stringValue ?? "", at: Date().timeIntervalSince1970
        )
        records[connector] = row
        return ["record": .object(row)]
    }

    private static func row(connector: String, step: String, completed: [String], device: String, at time: Double) -> [String: JSONValue] {
        [
            "connector": .string(connector), "bot": .null, "step_id": .string(step), "completed": .array(completed.map(JSONValue.string)),
            "device": .string(device), "updated_at": .double(time),
        ]
    }
}
