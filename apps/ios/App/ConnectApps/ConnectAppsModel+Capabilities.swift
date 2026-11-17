import Foundation
import PalAuth
import PalBotProfile
import PalClient
import PalConnect
import PalDesign
import PalDevice
import PalDiagnostics
import PalProtocol
import Observation

extension ConnectAppsModel {
    func loadCapabilities() async {
        guard let profile else { return }
        if case .ready = capabilitiesPhase {} else { capabilitiesPhase = .loading }
        do {
            let rows = try await capabilitiesService.status(profile: profile)
            capabilitiesPhase = .ready(rows)
            surfaces.remember(rows, capabilitiesKey)
        } catch is CancellationError {
            return
        } catch {
            diagnostics.info("capabilities", "status failed: \(Diagnostics.describe(error))")
            if case .ready = capabilitiesPhase {} else { capabilitiesPhase = .failed }
        }
    }

    var canSetKeys: Bool { profile != nil }

    func beginKeyEntry(_ row: CapabilityRow, keyName: String) {
        guard canSetKeys, row.settableKeys.contains(keyName) else { return }
        keyState = .idle
        keyRequest = CapabilityKeyRequest(capability: row.label, keyName: keyName)
    }

    func cancelKeyEntry() {
        keyRequest = nil
        keyState = .idle
    }

    func submitKey(_ value: String) async {
        guard let request = keyRequest, let profile, keyState.acceptsInput else { return }
        keyState = .submitting
        do {
            let rows = try await capabilitiesService.setKey(request.keyName, to: SecretString(value), profile: profile)
            capabilitiesPhase = .ready(rows)
            surfaces.remember(rows, capabilitiesKey)
            cancelKeyEntry()
        } catch is CancellationError {
            keyState = .idle
        } catch {
            diagnostics.info("capabilities", "set key failed: \(Diagnostics.describe(error))")
            keyState = .failure(String(localized: "Couldn't save the key. Check it and try again."))
        }
    }
}
