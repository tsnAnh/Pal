import Foundation
import HermesBotProfile
import Observation

@MainActor
@Observable
final class GatewayServiceModel {
    enum Notice: Equatable {
        case restarted(Date?)
        case restarting
        case installed
        case busy(String)
        case unavailable(String)
        case failure(String)
    }

    enum Activity: Equatable {
        case loading
        case restarting
        case installing
    }

    private(set) var info: GatewayServiceInfo?
    private(set) var activity: Activity?
    private(set) var notice: Notice?
    private(set) var loadFailed = false

    private let client: GatewayServiceClient

    init(client: GatewayServiceClient) {
        self.client = client
    }

    var isBusy: Bool { activity != nil }

    func load() async {
        guard activity == nil else { return }
        activity = .loading
        defer { activity = nil }
        do {
            info = try await client.status()
            loadFailed = false
        } catch is CancellationError {
        } catch {
            loadFailed = true
        }
    }

    func restart() async {
        guard activity == nil else { return }
        activity = .restarting
        notice = nil
        let outcome = await client.restart()
        activity = nil
        apply(outcome, success: { .restarted($0.startedAt) })
    }

    func install() async {
        guard activity == nil else { return }
        activity = .installing
        notice = nil
        let outcome = await client.install()
        activity = nil
        apply(outcome, success: { _ in .installed })
    }

    var noticeText: String? {
        switch notice {
        case .restarted(let date)?:
            if let date {
                String(localized: "Pal restarted. Running since \(date.formatted(date: .omitted, time: .shortened)).")
            } else {
                String(localized: "Pal restarted.")
            }
        case .restarting?: String(localized: "Pal is restarting. Check again in a moment.")
        case .installed?: String(localized: "Pal will now start automatically when you sign in.")
        case .busy(let reason)?, .unavailable(let reason)?, .failure(let reason)?: reason
        case nil: nil
        }
    }

    private func apply(_ outcome: GatewayServiceOutcome, success: (GatewayServiceInfo) -> Notice) {
        switch outcome {
        case .done(let latest):
            info = latest
            notice = success(latest)
        case .pending(let latest):
            info = latest ?? info
            notice = .restarting
        case .busy(let reason): notice = .busy(reason)
        case .refused(let reason), .unsupported(let reason): notice = .unavailable(reason)
        case .failed(let reason): notice = .failure(reason)
        }
    }
}
