import Foundation
import Testing
@testable import HermesDesign

@Suite("Secret entry")
struct SecretEntryTests {
    private static let states: [SecretEntryState] = [.idle, .submitting, .success, .failure("nope"), .cancelled, .expired]

    @Test("only success, cancelled and expired are terminal")
    func terminal() {
        let terminal = Self.states.filter(\.isTerminal)
        #expect(terminal == [.success, .cancelled, .expired])
    }

    @Test("input is accepted when idle or after a retryable failure")
    func acceptsInput() {
        let accepting = Self.states.filter(\.acceptsInput)
        #expect(accepting == [.idle, .failure("nope")])
    }

    @Test("the field must be empty while submitting and in every terminal state")
    func clearedWhenTerminal() {
        for state in Self.states {
            #expect(state.requiresEmptyField == (state.isTerminal || state == .submitting), "\(state)")
        }
        #expect(!SecretEntryState.idle.requiresEmptyField)
        #expect(!SecretEntryState.failure("x").requiresEmptyField)
    }

    @Test("slugs are stable, lowercase and unique")
    func slugs() {
        let slugs = Self.states.map(\.accessibilitySlug)
        #expect(slugs == ["idle", "submitting", "success", "failure", "cancelled", "expired"])
        #expect(Set(slugs).count == slugs.count)
        #expect(SecretEntryState.failure("a").accessibilitySlug == SecretEntryState.failure("b").accessibilitySlug)
    }

    @Test("status text is plain and the expired text tells the user what to do")
    func statusText() {
        #expect(SecretEntryState.idle.statusText == nil)
        #expect(SecretEntryState.failure("Couldn't save that.").statusText == "Couldn't save that.")
        #expect(SecretEntryState.expired.statusText == "This request has closed. Ask your bot to try again.")
        for state in Self.states where state != .idle { #expect(state.statusText?.isEmpty == false) }
    }

    @Test("input is trimmed and blank input is not submittable")
    func trimming() {
        #expect(SecretEntryInput.trimmed("  sk-123\n") == "sk-123")
        #expect(SecretEntryInput.trimmed(" \n\t") == nil)
        #expect(SecretEntryInput.trimmed("") == nil)
        #expect(SecretEntryInput.trimmed("a b") == "a b")
    }

    @Test("default identifiers follow the secret-entry contract")
    func identifiers() {
        let ids = SecretEntryIdentifiers()
        #expect(ids.field == "secret-entry-field")
        #expect(ids.submit == "secret-entry-submit")
        #expect(ids.cancel == "secret-entry-cancel")
        #expect(ids.status == "secret-entry-status")
    }
}
