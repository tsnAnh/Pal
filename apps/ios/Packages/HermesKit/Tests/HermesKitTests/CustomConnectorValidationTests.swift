import Foundation
import HermesConnect
import Testing

@Suite("Custom connector validation")
struct CustomConnectorValidationTests {
    private func draft(name: String = "notes", url: String = "https://mcp.example.com/mcp") -> CustomConnectorDraft {
        CustomConnectorDraft(name: name, url: url)
    }

    private func failure(_ draft: CustomConnectorDraft) -> CustomConnectorValidationError? {
        do { _ = try draft.validated(); return nil } catch { return error }
    }

    @Test func httpsIsAccepted() throws {
        let result = try draft().validated()
        #expect(result.name == "notes" && result.url == "https://mcp.example.com/mcp" && result.transport == .http)
    }

    @Test func httpIsAcceptedOnlyForLocalAndPrivateHosts() {
        for host in ["localhost", "box.local", "127.0.0.1", "127.8.9.1", "10.0.0.5", "172.16.0.1", "172.31.255.1", "192.168.1.20", "[::1]"] {
            #expect(failure(draft(url: "http://\(host):8080/mcp")) == nil, "\(host)")
        }
        for host in ["example.com", "8.8.8.8", "172.32.0.1", "172.15.0.1", "192.169.0.1", "11.0.0.1", "localhost.example.com", "169.254.1.1"] {
            #expect(failure(draft(url: "http://\(host)/mcp")) == .insecureURL, "\(host)")
        }
    }

    @Test func userInfoAndOddSchemesAreRejected() {
        #expect(failure(draft(url: "https://user:pw@example.com/mcp")) == .credentialsInURL)
        #expect(failure(draft(url: "https://user@example.com/mcp")) == .credentialsInURL)
        #expect(failure(draft(url: "ftp://example.com/mcp")) == .unsupportedScheme)
        #expect(failure(draft(url: "file:///etc/passwd")) == .unsupportedScheme)
        #expect(failure(draft(url: "example.com/mcp")) == .invalidURL)
        #expect(failure(draft(url: "https://")) == .invalidURL)
        #expect(failure(draft(url: "   ")) == .emptyURL)
    }

    @Test func nameMustBeANonEmptySafeKey() {
        #expect(failure(draft(name: "   ")) == .emptyName)
        #expect(failure(draft(name: "my server")) == .invalidName)
        #expect(failure(draft(name: "-lead")) == .invalidName)
        #expect(failure(draft(name: "a/b")) == .invalidName)
        #expect(failure(draft(name: String(repeating: "a", count: 49))) == .invalidName)
        #expect(failure(draft(name: "  my_server-2  ")) == nil)
    }

    @Test func bearerNeedsATokenUnlessEditingAnExistingBearerConnector() {
        var fresh = draft()
        fresh.auth = .bearer
        #expect(failure(fresh) == .tokenRequired)
        fresh.bearerToken = ConnectorSecret(randomToken())
        #expect(failure(fresh) == nil)
        var edit = draft()
        edit.auth = .bearer
        edit.originalAuth = .bearer
        #expect(failure(edit) == nil)
        edit.originalAuth = CustomConnectorAuth.none
        #expect(failure(edit) == .tokenRequired)
    }

    @Test func theTokenNeverShowsInAnyDescriptionOfTheDraft() {
        let token = randomToken()
        var value = draft()
        value.auth = .bearer
        value.bearerToken = ConnectorSecret(token)
        let texts = ["\(value)", String(describing: value), String(reflecting: value), "\(value.bearerToken!)", String(reflecting: value.bearerToken!)]
        var dumped = ""
        dump(value, to: &dumped)
        dump(value.bearerToken!, to: &dumped)
        for text in texts + [dumped] { #expect(!text.contains(token)) }
    }

    @Test func stateMachineFollowsTheHappyPath() {
        var machine = CustomConnectorMachine()
        let tools = [ConnectorTool(name: "search", description: "Find")]
        #expect(machine.send(.submit) && machine.phase == .validating)
        #expect(machine.send(.validated) && machine.phase == .saving)
        #expect(machine.send(.saved) && machine.phase == .connecting)
        #expect(machine.send(.connected(tools)) && machine.phase == .connected(tools))
        #expect(machine.send(.submit) && machine.phase == .validating)
    }

    @Test func stateMachineRejectsIllegalTransitionsAndRecoversFromFailure() {
        var machine = CustomConnectorMachine()
        #expect(!machine.send(.saved) && machine.phase == .idle)
        #expect(!machine.send(.failed(.unreachable)) && machine.phase == .idle)
        machine.send(.submit)
        #expect(!machine.send(.submit))
        #expect(!machine.send(.reset) && machine.phase == .validating)
        #expect(!machine.send(.connected([])))
        machine.send(.failed(.validation(.emptyName)))
        #expect(machine.phase == .failed(.validation(.emptyName)))
        #expect(machine.send(.submit) && machine.phase == .validating)
        machine.send(.validated)
        machine.send(.failed(.nameTaken))
        #expect(machine.send(.reset) && machine.phase == .idle)
        machine.send(.submit); machine.send(.validated); machine.send(.saved)
        #expect(machine.phase.isInFlight)
        machine.send(.failed(.noTools))
        #expect(machine.phase == .failed(.noTools) && !machine.phase.isInFlight)
    }
}
