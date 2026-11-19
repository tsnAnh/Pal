import Foundation
import PalClient
#if os(macOS)
import Security
#endif

enum SignedPushEnvironment {
    static func resolve() async -> PushEnvironment {
        await Task.detached(priority: .utility) {
            apsEntitlement() == "development" ? PushEnvironment.sandbox : .production
        }.value
    }

    nonisolated private static func apsEntitlement() -> String? {
        #if targetEnvironment(simulator)
        "development"
        #elseif os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.aps-environment" as CFString, nil) as? String
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url), // perf-lint: ok
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return nil }
        return entitlements["aps-environment"] as? String
        #endif
    }
}
