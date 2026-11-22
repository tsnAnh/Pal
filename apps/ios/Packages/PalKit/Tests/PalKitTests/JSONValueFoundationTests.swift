import Foundation
import PalProtocol
import Testing

@Suite("JSONValue foundation bridge")
struct JSONValueFoundationTests {
    private static let document = """
    {"flag":true,"off":false,"count":3,"zero":0,"one":1,"ratio":1.5,"whole":2.0,"name":"pal","nothing":null,
     "list":[1,"a",false,null,{"deep":[true,0.25]}],"nested":{"inner":{"k":"v"}}}
    """

    @Test func matchesJSONSerializationForEveryScalarAndContainer() throws {
        let data = Data(Self.document.utf8)
        let reference = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let bridged = try #require(try JSONDecoder().decode(JSONValue.self, from: data).foundationObject as? [String: Any])
        #expect(NSDictionary(dictionary: bridged).isEqual(to: reference))
    }

    @Test func keepsBooleansAndNumbersApart() throws {
        let bridged = try #require(JSONValue.object(["flag": true, "one": 1, "ratio": 1.5]).foundationObject as? [String: Any])
        #expect(bridged["flag"] as? Bool == true)
        #expect(bridged["one"] as? Int == 1)
        #expect(bridged["one"] as? Double == 1)
        #expect(bridged["ratio"] as? Double == 1.5)
        #expect(bridged["ratio"] as? Int == nil)
    }
}
