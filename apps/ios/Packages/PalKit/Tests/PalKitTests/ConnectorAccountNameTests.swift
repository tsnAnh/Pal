import PalProtocol
import Testing

@Suite("Connector account names")
struct ConnectorAccountNameTests {
    @Test(arguments: ["default", "work", "a", "0", "a-b", "a--b", "work-2", "9lives", String(repeating: "a", count: 32)])
    func goodNamesPass(_ name: String) {
        #expect(ConnectorAccountName.validate(name) == nil)
        #expect(ConnectorAccountName.isValid(name))
    }

    @Test func anEmptyNameIsReported() {
        #expect(ConnectorAccountName.validate("") == .empty)
        #expect(!ConnectorAccountName.isValid(""))
    }

    @Test func aNameLongerThan32IsReported() {
        #expect(ConnectorAccountName.validate(String(repeating: "a", count: 33)) == .tooLong)
        #expect(ConnectorAccountName.maxLength == 32)
    }

    @Test(arguments: ["Work", "WORK", "wOrk", "my_work", "my work", "work.", "wörk", "work!", "a/b", "a@b", "a:b"])
    func disallowedCharactersAreReported(_ name: String) {
        #expect(ConnectorAccountName.validate(name) == .invalidCharacter)
    }

    @Test(arguments: ["-work", "-", "--a"])
    func aLeadingHyphenIsReported(_ name: String) {
        #expect(ConnectorAccountName.validate(name) == .leadingHyphen)
    }

    @Test func nothingIsTrimmedOrLowercasedSilently() {
        #expect(ConnectorAccountName.validate(" work") == .invalidCharacter)
        #expect(ConnectorAccountName.validate("work ") == .invalidCharacter)
        #expect(ConnectorAccountName.validate("\nwork") == .invalidCharacter)
        #expect(ConnectorAccountName.validate("Work") == .invalidCharacter)
    }

    @Test func aNameAlreadyInUseIsReportedOnlyWhenOtherwiseValid() {
        #expect(ConnectorAccountName.validate("work", existing: ["default", "work"]) == .taken)
        #expect(ConnectorAccountName.validate("personal", existing: ["default", "work"]) == nil)
        #expect(ConnectorAccountName.validate("Work", existing: ["work"]) == .invalidCharacter)
        #expect(ConnectorAccountName.validate("", existing: [""]) == .empty)
    }

    @Test func everyProblemHasPlainOneLineWords() {
        let all: [ConnectorAccountNameError] = [.empty, .tooLong, .invalidCharacter, .leadingHyphen, .taken]
        for problem in all {
            let text = problem.message
            #expect(!text.isEmpty)
            #expect(!text.contains("\n"))
            for banned in ["regex", "pattern", "slug", "alias", "@", "RPC", "[a-z"] {
                #expect(!text.localizedCaseInsensitiveContains(banned))
            }
        }
        #expect(Set(all.map(\.message)).count == all.count)
    }
}

@Suite("Connector account name suggestions")
struct ConnectorAccountSuggestionTests {
    @Test func theFirstAccountSuggestsDefault() {
        #expect(ConnectorAccountName.suggest(existing: []) == "default")
    }

    @Test func thenWorkThenPersonal() {
        #expect(ConnectorAccountName.suggest(existing: ["default"]) == "work")
        #expect(ConnectorAccountName.suggest(existing: ["default", "work"]) == "personal")
    }

    @Test func thenNumberedNamesCountingUpFromTwo() {
        let named = ["default", "work", "personal"]
        #expect(ConnectorAccountName.suggest(existing: named) == "account-2")
        #expect(ConnectorAccountName.suggest(existing: named + ["account-2"]) == "account-3")
        #expect(ConnectorAccountName.suggest(existing: named + ["account-2", "account-3", "account-5"]) == "account-4")
    }

    @Test func aFreedNameIsOfferedAgain() {
        #expect(ConnectorAccountName.suggest(existing: ["work"]) == "default")
        #expect(ConnectorAccountName.suggest(existing: ["personal", "default"]) == "work")
    }

    @Test func neverAnExistingNameAndNeverInvalid() {
        var existing: [String] = []
        for _ in 0..<60 {
            let next = ConnectorAccountName.suggest(existing: existing)
            #expect(!existing.contains(next))
            #expect(ConnectorAccountName.validate(next, existing: existing) == nil)
            existing.append(next)
        }
        #expect(existing.prefix(5) == ["default", "work", "personal", "account-2", "account-3"])
    }

    @Test func existingNamesThatAreNotValidDoNotConfuseIt() {
        #expect(ConnectorAccountName.suggest(existing: ["Default", "work"]) == "default")
    }
}
