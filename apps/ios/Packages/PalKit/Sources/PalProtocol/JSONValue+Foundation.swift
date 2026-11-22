import Foundation

extension JSONValue {
    public var foundationObject: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): NSNumber(value: value)
        case .int(let value): NSNumber(value: value)
        case .double(let value): NSNumber(value: value)
        case .string(let value): value
        case .array(let value): value.map(\.foundationObject)
        case .object(let value): value.mapValues(\.foundationObject)
        }
    }
}
