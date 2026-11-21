import Foundation
import PalProtocol
import PalTransport

public struct ShopifyFailure: Error, Sendable, Equatable {
    public var status: SetupStatus
}

public enum ShopifyFlow {
    public static let flowID = "shopify"

    public static func steps() -> [FlowStep] {
        [
            FlowStep(
                id: "address", title: String(localized: "Enter your store address"),
                body: String(localized: "Use your store's address, like your-store.myshopify.com. A store with its own web address works too."),
                kind: .paste(fields: [SetupField(id: "address", label: String(localized: "Store address"), secret: false)]),
                primaryTitle: String(localized: "Connect store")
            ),
            FlowStep(
                id: "done", title: String(localized: "Connected"),
                kind: .success(
                    title: String(localized: "Shopify is connected"),
                    body: String(localized: "Your bots can search this store's products and policies and manage a cart. You will not be asked for this again.")
                )
            ),
        ]
    }

    public static func engine() -> StepFlowEngine? {
        StepFlowEngine(flowID: flowID, steps: steps(), resume: nil)
    }

    public static func runner(service: ConnectAppsService) -> StepFlowModel.Runner {
        { step, values in
            if step.id == "address" { try await service.connectShopify(values["address"] ?? "") }
        }
    }

    public static func classify(_ error: any Error) -> SetupStatus {
        let subject = ShopifyConnector.name
        switch error {
        case let failure as ShopifyFailure:
            return failure.status
        case let address as ShopifyAddressError:
            var status = SetupStatus(code: SetupStatusClass.vendorRefusedValue.rawValue, subject: subject, valueName: "address")
            status.title = String(localized: "That address does not look right")
            status.reason = address.message
            status.code = "invalid_address"
            return status
        case let failure as ConnectAppsError:
            return AddressedFlowStatus.fromConnect(failure, subject: subject)
        case let transport as GatewayTransportError:
            return AddressedFlowStatus.fromTransport(transport, subject: subject)
        case let failure as ConnectorFailure:
            return AddressedFlowStatus.fromConnector(failure, subject: subject)
        default:
            return SetupStatus(code: SetupStatusClass.internalFault.rawValue, subject: subject)
        }
    }
}

extension ConnectAppsService {
    public func connectShopify(_ input: String) async throws {
        let url = try ShopifyConnector.mcpURL(fromInput: input)
        let created = try await saveAddressedServer(name: ShopifyConnector.slug, url: url)
        do {
            let result = try await call("mcp.servers.test", ["name": .string(ShopifyConnector.slug)])
            if result["ok"]?.boolValue != true {
                let status = Self.addressedFailure(testResult: result, subject: ShopifyConnector.name)
                    ?? SetupStatus(code: SetupStatusClass.notMcpServer.rawValue, method: "mcp.servers.test", subject: ShopifyConnector.name)
                throw ShopifyFailure(status: status)
            }
        } catch {
            if created { await removeQuietly(ShopifyConnector.slug) }
            throw error
        }
    }
}
