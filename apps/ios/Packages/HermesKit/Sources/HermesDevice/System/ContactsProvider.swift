import Contacts
import Foundation

public struct SystemContacts: ContactsProviding {
    public init() {}

    public func search(_ query: String, limit: Int) async throws -> [ContactRecord] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let store = CNContactStore()
                let keys: [CNKeyDescriptor] = [
                    CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                    CNContactOrganizationNameKey as CNKeyDescriptor,
                    CNContactPhoneNumbersKey as CNKeyDescriptor,
                    CNContactEmailAddressesKey as CNKeyDescriptor,
                ]
                do {
                    let found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)
                    let records = found.prefix(limit).map { contact in
                        ContactRecord(
                            id: contact.identifier,
                            name: CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName,
                            organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
                            phones: contact.phoneNumbers.map { $0.value.stringValue },
                            emails: contact.emailAddresses.map { $0.value as String }
                        )
                    }
                    continuation.resume(returning: Array(records))
                } catch {
                    continuation.resume(throwing: DeviceProviderError.failed("Contacts could not be searched."))
                }
            }
        }
    }
}
