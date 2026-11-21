import PalProtocol

extension ServiceSignInDialog {
    public var account: String? { McpServiceID(service: service)?.account }

    public var displayTitle: String { McpServiceID(service: service)?.displayTitle(vendor: serviceName) ?? serviceName }
}
