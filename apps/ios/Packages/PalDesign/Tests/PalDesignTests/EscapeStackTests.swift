import Foundation
@testable import PalDesign
import Testing

@MainActor
@Suite("Escape stack")
struct EscapeStackTests {
    final class Log {
        var closed: [String] = []
    }

    @discardableResult
    private func open(
        _ stack: MacEscapeStack, _ name: String, _ layer: EscapeLayer, nested: Bool = false,
        policy: EscapePolicy = .dismisses, log: Log
    ) -> UUID {
        let id = UUID()
        stack.register(id, layer: layer, nested: nested, policy: policy) { log.closed.append(name) }
        return id
    }

    @Test func escapeClosesTheOnlyPopup() {
        let (stack, log) = (MacEscapeStack(), Log())
        open(stack, "panel", .panel, log: log)
        #expect(stack.press() == .dismiss)
        #expect(log.closed == ["panel"])
    }

    @Test func escapeWithNothingOpenIsIgnored() {
        let stack = MacEscapeStack()
        #expect(!stack.hasEntries)
        #expect(stack.press() == .ignore)
    }

    @Test func aMenuClosesBeforeThePopupItSitsIn() {
        let (stack, log) = (MacEscapeStack(), Log())
        open(stack, "panel", .panel, log: log)
        let menu = open(stack, "menu", .menu, log: log)
        stack.press()
        stack.unregister(menu)
        stack.press()
        #expect(log.closed == ["menu", "panel"])
    }

    @Test func onlyTheTopOfAStackOfSheetsReacts() {
        let (stack, log) = (MacEscapeStack(), Log())
        open(stack, "first", .sheet, log: log)
        let second = open(stack, "second", .sheet, log: log)
        stack.press()
        #expect(log.closed == ["second"])
        stack.unregister(second)
        stack.press()
        #expect(log.closed == ["second", "first"])
    }

    @Test func aSheetOpensAbovePanelsButBelowDialogsWhateverTheOpeningOrder() {
        let (stack, log) = (MacEscapeStack(), Log())
        open(stack, "dialog", .dialog, log: log)
        open(stack, "sheet", .sheet, log: log)
        open(stack, "panel", .panel, log: log)
        open(stack, "stepFlow", .stepFlow, log: log)
        stack.press()
        #expect(log.closed == ["dialog"])
    }

    @Test func aStepFlowPanelClosesBeforeThePanelUnderneathAndAfterASheetOverIt() {
        let (stack, log) = (MacEscapeStack(), Log())
        open(stack, "panel", .panel, log: log)
        open(stack, "stepFlow", .stepFlow, log: log)
        stack.press()
        #expect(log.closed == ["stepFlow"])
        open(stack, "sheet", .sheet, log: log)
        stack.press()
        #expect(log.closed == ["stepFlow", "sheet"])
    }

    @Test func aNestedBackStepClosesBeforeThePopupThatHostsIt() {
        let (stack, log) = (MacEscapeStack(), Log())
        open(stack, "panel", .panel, log: log)
        let back = open(stack, "back", .panel, nested: true, log: log)
        stack.press()
        stack.unregister(back)
        stack.press()
        #expect(log.closed == ["back", "panel"])
    }

    @Test func aNestedBackStepInASheetDoesNotOutrankASheetOnTop() {
        let (stack, log) = (MacEscapeStack(), Log())
        open(stack, "panelBack", .panel, nested: true, log: log)
        open(stack, "sheet", .sheet, log: log)
        stack.press()
        #expect(log.closed == ["sheet"])
    }

    @Test(arguments: [EscapePolicy.Reason.inFlight, .requiredStep, .blockingError])
    func aBlockedPopupIgnoresEscapeAndTheOnesBelowStayOpen(reason: EscapePolicy.Reason) {
        let (stack, log) = (MacEscapeStack(), Log())
        open(stack, "panel", .panel, log: log)
        open(stack, "sheet", .sheet, policy: .blocked(reason), log: log)
        #expect(stack.press() == .ignore)
        #expect(log.closed.isEmpty)
        #expect(stack.dialogs.current == nil)
    }

    @Test func aPopupWithUnsavedInputAsksToDiscardInsteadOfClosing() throws {
        let (stack, log) = (MacEscapeStack(), Log())
        open(stack, "sheet", .sheet, policy: .blocked(.unsavedInput), log: log)
        #expect(stack.press() == .confirmDiscard)
        #expect(log.closed.isEmpty)
        let dialog = try #require(stack.dialogs.current)
        #expect(dialog.content.title == "Discard changes?")
        #expect(dialog.content.actions.map(\.role) == [.cancel, .destructive])
        #expect(dialog.content.actions.map(\.title) == ["Keep editing", "Discard"])
    }

    @Test func escapeOnTheDiscardPromptKeepsEditing() throws {
        let (stack, log) = (MacEscapeStack(), Log())
        open(stack, "sheet", .sheet, policy: .blocked(.unsavedInput), log: log)
        stack.press()
        try #require(stack.dialogs.current).press(.escape)
        #expect(stack.dialogs.current == nil)
        #expect(log.closed.isEmpty)
    }

    @Test func discardingFromThePromptClosesThePopup() throws {
        let (stack, log) = (MacEscapeStack(), Log())
        open(stack, "sheet", .sheet, policy: .blocked(.unsavedInput), log: log)
        stack.press()
        let dialog = try #require(stack.dialogs.current)
        dialog.activate(try #require(dialog.content.actions.first { $0.role == .destructive }))
        #expect(log.closed == ["sheet"])
        #expect(stack.dialogs.current == nil)
    }

    @Test func registeringAgainUpdatesThePolicyInPlace() {
        let (stack, log) = (MacEscapeStack(), Log())
        let id = open(stack, "sheet", .sheet, policy: .blocked(.inFlight), log: log)
        open(stack, "other", .panel, log: log)
        #expect(stack.press() == .ignore)
        stack.register(id, layer: .sheet, policy: .dismisses) { log.closed.append("sheet") }
        #expect(stack.press() == .dismiss)
        #expect(log.closed == ["sheet"])
    }

    @Test func aClosedPopupLeavesTheStackEmpty() {
        let (stack, log) = (MacEscapeStack(), Log())
        let id = open(stack, "panel", .panel, log: log)
        stack.unregister(id)
        #expect(!stack.hasEntries)
    }
}

@Suite("Escape policy")
struct EscapePolicyTests {
    @Test func everyReasonStatesItselfInOneLine() {
        for reason in EscapePolicy.Reason.allCases {
            #expect(!reason.summary.isEmpty)
            #expect(!reason.summary.contains("\n"))
        }
    }

    @Test func onlyUnsavedInputAsksToDiscardAndTheOtherReasonsIgnoreEscape() {
        #expect(EscapePolicy.dismisses.outcome == .dismiss)
        for reason in EscapePolicy.Reason.allCases {
            #expect(EscapePolicy.blocked(reason).outcome == (reason == .unsavedInput ? .confirmDiscard : .ignore))
        }
    }

    @Test func theCloseButtonStaysOnlyWhereTheOwnerCanStillChooseToLeave() {
        #expect(EscapePolicy.dismisses.allowsClose)
        #expect(EscapePolicy.blocked(.unsavedInput).allowsClose)
        for reason in EscapePolicy.Reason.allCases where reason != .unsavedInput {
            #expect(!EscapePolicy.blocked(reason).allowsClose)
        }
    }

    @Test func aConditionPicksBetweenDismissingAndTheNamedReason() {
        #expect(EscapePolicy(blocking: .inFlight, when: false) == .dismisses)
        #expect(EscapePolicy(blocking: .inFlight, when: true) == .blocked(.inFlight))
    }

    @Test func theStrictestPolicyOfSeveralViewsWins() {
        var value = EscapePolicy.dismisses
        EscapePolicyKey.reduce(value: &value) { .blocked(.unsavedInput) }
        EscapePolicyKey.reduce(value: &value) { .blocked(.inFlight) }
        EscapePolicyKey.reduce(value: &value) { .dismisses }
        #expect(value == .blocked(.inFlight))
    }
}
