import Foundation
import PalBotProfile
import PalProtocol

enum CapabilitiesScript {
    static let argument = "-hermes-test-capabilities"
    static let failFirstArgument = "-hermes-test-capabilities-fail-first"

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static func wrap(_ call: @escaping BotsGateway.Call) -> BotsGateway.Call {
        guard isActive else { return call }
        let gateway = ScriptedCapabilitiesGateway(failsFirstStatus: ProcessInfo.processInfo.arguments.contains(failFirstArgument))
        return { method, params in
            switch method {
            case "capabilities.status":
                return try await gateway.status()
            case "capabilities.set_key":
                return try await gateway.setKey(params?["key_name"]?.stringValue)
            default:
                return try await call(method, params)
            }
        }
    }
}

struct ScriptedCapabilitiesFailure: Error {}

actor ScriptedCapabilitiesGateway {
    private var failsNextStatus: Bool
    private var mapsKeySet = false

    init(failsFirstStatus: Bool) {
        failsNextStatus = failsFirstStatus
    }

    func status() throws -> JSONValue {
        if failsNextStatus {
            failsNextStatus = false
            throw ScriptedCapabilitiesFailure()
        }
        return payload
    }

    func setKey(_ keyName: String?) throws -> JSONValue {
        guard keyName == "GOOGLE_MAPS_API_KEY" else { throw ScriptedCapabilitiesFailure() }
        mapsKeySet = true
        return payload
    }

    private var payload: JSONValue {
        let maps: JSONValue = mapsKeySet
            ? ["id": "maps", "label": "Maps", "state": "on", "key_name": "GOOGLE_MAPS_API_KEY"]
            : [
                "id": "maps", "label": "Maps", "state": "on", "key_name": "GOOGLE_MAPS_API_KEY",
                "reason": "Maps uses OpenStreetMap only. Add GOOGLE_MAPS_API_KEY for Google results.",
            ]
        return [
            "profile": "scripted",
            "capabilities": [
                ["id": "web", "label": "Web search", "state": "on"],
                maps,
                [
                    "id": "deep_search", "label": "Deep search", "state": "off", "reason": "Needs a search key.",
                    "key_choices": ["EXA_API_KEY", "TAVILY_API_KEY"],
                ],
                ["id": "browser", "label": "Browser", "state": "off", "reason": "Pick a browser provider in settings.", "setting": "browser.cloud_provider"],
                ["id": "youtube", "label": "YouTube", "state": "unavailable", "reason": "Not installed."],
            ],
        ]
    }
}
