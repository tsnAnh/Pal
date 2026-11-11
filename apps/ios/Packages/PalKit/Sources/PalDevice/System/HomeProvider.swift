#if canImport(HomeKit) && os(iOS)
import Foundation
import PalProtocol
import HomeKit

@MainActor
final class HomeService: NSObject, HMHomeManagerDelegate {
    static let shared = HomeService()

    private var manager: HMHomeManager?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var ready = false

    var authorization: HMHomeManagerAuthorizationStatus? {
        manager?.authorizationStatus
    }

    func prepare() async -> HMHomeManager {
        if let manager, ready { return manager }
        if manager == nil {
            let created = HMHomeManager()
            created.delegate = self
            manager = created
        }
        if !ready {
            await withCheckedContinuation { continuation in waiters.append(continuation) }
        }
        return manager!
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in self.finishLoading() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor in
            if status.contains(.determined), !status.contains(.authorized) { self.finishLoading() }
        }
    }

    private func finishLoading() {
        ready = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func accessories(inRoom room: String?) async throws -> [AccessoryRecord] {
        let manager = await prepare()
        var records: [AccessoryRecord] = []
        for home in manager.homes {
            for accessory in home.accessories {
                let roomName = accessory.room?.name
                if let room, roomName?.localizedCaseInsensitiveCompare(room) != .orderedSame { continue }
                records.append(Self.record(accessory))
            }
        }
        return records
    }

    func set(accessoryID: String, characteristic: HomeCharacteristic, value: JSONValue) async throws -> AccessoryRecord {
        let manager = await prepare()
        guard let accessory = manager.homes.flatMap(\.accessories).first(where: { $0.uniqueIdentifier.uuidString == accessoryID }) else {
            throw DeviceProviderError.notFound
        }
        guard accessory.isReachable else { throw DeviceProviderError.failed("The accessory is not reachable.") }
        let type = Self.type(of: characteristic)
        guard let target = accessory.services.flatMap(\.characteristics).first(where: { $0.characteristicType == type }) else {
            throw DeviceProviderError.unsupported
        }
        let converted: Any
        switch (characteristic, value) {
        case (.power, .bool(let flag)): converted = flag
        case (.lock, .bool(let flag)): converted = flag ? 1 : 0
        case (.brightness, .int(let number)): converted = number
        case (.brightness, .double(let number)): converted = Int(number.rounded())
        case (.targetTemperature, .int(let number)): converted = Double(number)
        case (.targetTemperature, .double(let number)): converted = number
        default: throw DeviceProviderError.invalidArgs("That value does not fit \(characteristic.rawValue).")
        }
        do { try await target.writeValue(converted) } catch { throw DeviceProviderError.failed("The accessory did not accept the change.") }
        return Self.record(accessory)
    }

    private static func type(of characteristic: HomeCharacteristic) -> String {
        switch characteristic {
        case .power: HMCharacteristicTypePowerState
        case .brightness: HMCharacteristicTypeBrightness
        case .lock: HMCharacteristicTypeTargetLockMechanismState
        case .targetTemperature: HMCharacteristicTypeTargetTemperature
        }
    }

    private static func record(_ accessory: HMAccessory) -> AccessoryRecord {
        var state: [String: JSONValue] = [:]
        for characteristic in accessory.services.flatMap(\.characteristics) {
            guard let value = characteristic.value else { continue }
            switch characteristic.characteristicType {
            case HMCharacteristicTypePowerState: if let flag = value as? Bool { state["power"] = .bool(flag) }
            case HMCharacteristicTypeBrightness: if let number = value as? Int { state["brightness"] = .int(number) }
            case HMCharacteristicTypeTargetLockMechanismState: if let number = value as? Int { state["lock"] = .bool(number == 1) }
            case HMCharacteristicTypeTargetTemperature: if let number = value as? Double { state["target_temperature"] = .double(number) }
            default: continue
            }
        }
        return AccessoryRecord(
            id: accessory.uniqueIdentifier.uuidString, name: accessory.name, room: accessory.room?.name,
            category: accessory.category.localizedDescription, isReachable: accessory.isReachable, state: state
        )
    }
}

public struct SystemHome: HomeProviding {
    public init() {}

    public func accessories(inRoom room: String?) async throws -> [AccessoryRecord] {
        try await HomeService.shared.accessories(inRoom: room)
    }

    public func set(accessoryID: String, characteristic: HomeCharacteristic, value: JSONValue) async throws -> AccessoryRecord {
        try await HomeService.shared.set(accessoryID: accessoryID, characteristic: characteristic, value: value)
    }
}
#endif
