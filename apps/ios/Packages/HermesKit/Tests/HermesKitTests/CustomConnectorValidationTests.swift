import Foundation
import HermesConnect
import Testing

@Suite("Custom connector validation")
struct CustomConnectorValidationTests {
    private func draft(name: String = "notes", url: String = "https://mcp.example.com/mcp", headers: [ConnectorHeader] = []) -> CustomConnectorDraft {
        CustomConnectorDraft(name: name, url: url, headers: headers)
    }

    private func failure(_ draft: CustomConnectorDraft) -> CustomConnectorValidationError? {
        do { _ = try draft.validated(); return nil } catch { return error }
    }

    @Test func typeOptionsAreExactlyWhatTheGatewayAccepts() {
        #expect(CustomConnectorType.options.map(\.label) == ["Remote HTTPS", "Remote HTTPS (SSE)"])
        #expect(CustomConnectorType.options.map(\.transport) == ["http", "sse"])
        #expect(CustomConnectorDraft().type == .remoteHTTPS)
    }

    @Test func httpsIsAccepted() throws {
        let result = try draft().validated()
        #expect(result.name == "notes" && result.url == "https://mcp.example.com/mcp" && result.type == .remoteHTTPS)
    }

    @Test func aMissingSchemeGetsHttpsForPublicHostsAndHttpForLocalOnes() throws {
        #expect(try draft(url: "example.com/mcp").validated().url == "https://example.com/mcp")
        #expect(try draft(url: "  8.8.8.8:9000/mcp ").validated().url == "https://8.8.8.8:9000/mcp")
        for host in ["localhost:8080/mcp", "127.0.0.1/mcp", "10.0.0.5:3000/mcp", "192.168.1.20/mcp", "box.local/mcp", "[::1]:8080/mcp"] {
            #expect(try draft(url: host).validated().url == "http://" + host, "\(host)")
        }
        #expect(ConnectorURL.normalized("https://example.com/mcp") == "https://example.com/mcp")
        #expect(ConnectorURL.normalized("http://localhost:1/x") == "http://localhost:1/x")
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
        #expect(failure(draft(url: "user:pw@example.com/mcp")) == .credentialsInURL)
        #expect(failure(draft(url: "ftp://example.com/mcp")) == .unsupportedScheme)
        #expect(failure(draft(url: "file:///etc/passwd")) == .unsupportedScheme)
        #expect(failure(draft(url: "https://")) == .invalidURL)
        #expect(failure(draft(url: "   ")) == .emptyURL)
    }

    @Test func addPluginNeedsANameAndAValidURL() {
        #expect(!CustomConnectorDraft().canSubmit)
        #expect(!draft(name: "  ").canSubmit)
        #expect(!draft(url: "").canSubmit)
        #expect(!draft(url: "http://example.com/mcp").canSubmit)
        #expect(!draft(url: "user:pw@example.com").canSubmit)
        #expect(draft().canSubmit)
        #expect(draft(url: "example.com/mcp").canSubmit)
        #expect(draft(url: "localhost:8080/mcp").canSubmit)
        #expect(draft(url: "example.com/mcp").normalizedURL == "https://example.com/mcp")
    }

    @Test func nameMustBeANonEmptySafeKey() {
        #expect(failure(draft(name: "   ")) == .emptyName)
        #expect(failure(draft(name: "my server")) == .invalidName)
        #expect(failure(draft(name: "-lead")) == .invalidName)
        #expect(failure(draft(name: "a/b")) == .invalidName)
        #expect(failure(draft(name: String(repeating: "a", count: 49))) == .invalidName)
        #expect(failure(draft(name: "  my_server-2  ")) == nil)
    }

    @Test func headersNeedValidNamesAndValuesAndNoDuplicates() throws {
        let value = randomSecret()
        #expect(failure(draft(headers: [ConnectorHeader(key: "Authorization", value: value)])) == nil)
        #expect(failure(draft(headers: [ConnectorHeader(key: "Authorization", value: value), ConnectorHeader()])) == nil)
        #expect(failure(draft(headers: [ConnectorHeader(key: "Bad Name", value: value)])) == .invalidHeader)
        #expect(failure(draft(headers: [ConnectorHeader(key: "", value: value)])) == .invalidHeader)
        #expect(failure(draft(headers: [ConnectorHeader(key: "X-Key", value: "")])) == .invalidHeader)
        #expect(failure(draft(headers: [ConnectorHeader(key: "X-Key", value: "a\r\nInjected: 1")])) == .invalidHeader)
        #expect(failure(draft(headers: [ConnectorHeader(key: "X-Key", value: value), ConnectorHeader(key: "x-key", value: value)])) == .duplicateHeader)
        #expect(failure(draft(headers: [ConnectorHeader(key: "X-Key", isStored: true)])) == nil)
        #expect(try draft(headers: [ConnectorHeader(key: "X-Key", isStored: true)]).validated().headers.count == 1)
    }

    @Test func aNewHeaderRowAppearsWhenTheLastOneHasAnything() {
        var rows = ConnectorHeader.withTrailingBlank([])
        #expect(rows.count == 1 && rows[0].isBlank)
        #expect(ConnectorHeader.withTrailingBlank(rows).count == 1)
        rows[0].key = "X-Key"
        rows = ConnectorHeader.withTrailingBlank(rows)
        #expect(rows.count == 2 && rows[1].isBlank)
        rows[1].value = randomSecret()
        rows = ConnectorHeader.withTrailingBlank(rows)
        #expect(rows.count == 3 && rows[2].isBlank)
        let stored = ConnectorHeader.stored(keys: ["A", "B"])
        #expect(stored.count == 3 && stored[0].isStored && !stored[0].isBlank && stored[2].isBlank)
    }

    @Test func headerValuesNeverShowInAnyDescriptionOfTheDraft() {
        let secret = randomSecret()
        let row = ConnectorHeader(key: "Authorization", value: secret)
        let value = draft(headers: [row])
        let texts = ["\(value)", String(describing: value), String(reflecting: value), "\(row)", String(reflecting: row)]
        var dumped = ""
        dump(value, to: &dumped)
        dump(row, to: &dumped)
        for text in texts + [dumped] { #expect(!text.contains(secret)) }
        let validated = try? value.validated()
        #expect(!"\(String(describing: validated))".contains(secret))
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
