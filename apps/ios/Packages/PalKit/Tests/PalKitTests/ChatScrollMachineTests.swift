import Foundation
import PalChat
import Testing

private func geo(
    offset: Double,
    content: Double = 1000,
    container: Double = 500,
    width: Double = 400,
    insetTop: Double = 0,
    insetBottom: Double = 0,
    anchor: ChatRowAnchor? = nil
) -> ChatScrollGeometry {
    ChatScrollGeometry(
        offsetY: offset,
        contentHeight: content,
        containerHeight: container,
        containerWidth: width,
        insetTop: insetTop,
        insetBottom: insetBottom,
        topAnchor: anchor
    )
}

private func bottomGeo(content: Double = 1000, container: Double = 500, insetBottom: Double = 0) -> ChatScrollGeometry {
    geo(offset: content - container, content: content, container: container, insetBottom: insetBottom)
}

private func awayGeo(_ distance: Double, content: Double = 1000, container: Double = 500) -> ChatScrollGeometry {
    geo(offset: content - container - distance, content: content, container: container)
}

private func anchor(_ id: String, _ offset: Double = 0) -> ChatRowAnchor {
    ChatRowAnchor(rowID: id, offsetInRow: offset)
}

private func readingMachine(anchor top: ChatRowAnchor? = nil, rows: [String] = ["a", "b", "c"]) -> ChatScrollMachine {
    var machine = ChatScrollMachine()
    _ = machine.handle(.rowsChanged(rows))
    _ = machine.handle(.geometry(bottomGeo()))
    _ = machine.handle(.geometry(geo(offset: 300, anchor: top)))
    return machine
}

@Suite("Chat scroll machine")
struct ChatScrollMachineTests {
    @Test func startsPinnedWithNothingUnseen() {
        let machine = ChatScrollMachine()
        #expect(machine.state == .pinnedToBottom)
        #expect(machine.unseen == 0)
        #expect(!machine.showsJumpButton)
    }

    @Test func geometryDerivesDistancesAndSizeEquality() {
        let g = geo(offset: 100, content: 1000, container: 500, insetTop: 20, insetBottom: 30)
        #expect(g.distanceFromBottom == 380)
        #expect(g.distanceFromTop == 120)
        #expect(g.sameSize(as: geo(offset: 0, content: 1000.4, container: 500, insetTop: 20, insetBottom: 30)))
        #expect(!g.sameSize(as: geo(offset: 100, content: 1001, container: 500, insetTop: 20, insetBottom: 30)))
        #expect(geo(offset: 0, content: 1200, container: 500).wantsOlder)
        #expect(!geo(offset: 5000, content: 9000, container: 500).wantsOlder)
        #expect(geo(offset: 5000, content: 600, container: 500).wantsOlder)
    }

    @Test func theBottomInsetNeverEntersTheDistance() {
        let atBottom = geo(offset: 500, content: 1000, container: 500, insetBottom: 160)
        #expect(atBottom.distanceFromBottom == 0)
        #expect(geo(offset: 440, content: 1000, container: 500, insetBottom: 160).distanceFromBottom == 60)
        #expect(geo(offset: 500, content: 1000, container: 500, insetTop: 52, insetBottom: 160).distanceFromBottom == 0)
        #expect(geo(offset: 448, content: 1000, container: 500, insetTop: 52, insetBottom: 160).distanceFromBottom == 0)
        #expect(geo(offset: 400, content: 1000, container: 500, insetTop: 52, insetBottom: 160).distanceFromBottom == 48)
    }

    @Test func pinnedStaysSilentOnGrowthAtTheBottom() {
        var machine = ChatScrollMachine()
        #expect(machine.handle(.geometry(bottomGeo())) == .none)
        #expect(machine.handle(.geometry(bottomGeo(content: 1100))) == .none)
        #expect(machine.handle(.geometry(bottomGeo(content: 1100, insetBottom: 80))) == .none)
        #expect(machine.state == .pinnedToBottom)
    }

    @Test func pinnedRepairsASizeChangeDisplacementOnce() {
        var machine = ChatScrollMachine()
        _ = machine.handle(.geometry(bottomGeo()))
        #expect(machine.handle(.geometry(geo(offset: 550, content: 1100))) == .scrollToBottom(animated: false))
        #expect(machine.handle(.geometry(bottomGeo(content: 1100))) == .none)
        #expect(machine.state == .pinnedToBottom)
        #expect(machine.handle(.geometry(geo(offset: 620, content: 1200))) == .scrollToBottom(animated: false))
    }

    @Test func pinnedRepairsAreCappedAtMaxRepairs() {
        var machine = ChatScrollMachine()
        _ = machine.handle(.geometry(bottomGeo()))
        var commands: [ChatScrollMachine.Command] = []
        for step in 1...(ChatScrollMachine.maxRepairs + 2) {
            let content = 1000 + Double(step) * 100
            commands.append(machine.handle(.geometry(geo(offset: content - 500 - 40, content: content))))
        }
        let repairs = commands.filter { $0 == .scrollToBottom(animated: false) }
        #expect(repairs.count == ChatScrollMachine.maxRepairs)
        #expect(commands.suffix(2).allSatisfy { $0 == .none })
        #expect(machine.state == .pinnedToBottom)
    }

    @Test func offsetOnlyMoveLeavesPinnedForReading() {
        var machine = ChatScrollMachine()
        _ = machine.handle(.geometry(bottomGeo()))
        #expect(machine.handle(.geometry(geo(offset: 300))) == .none)
        #expect(machine.state == .readingHistory)
        #expect(machine.showsJumpButton)
    }

    @Test func readingEmitsNothingOnGrowthInsetGrowthOrResize() {
        var machine = readingMachine()
        #expect(machine.handle(.geometry(geo(offset: 300, content: 1300))) == .none)
        #expect(machine.handle(.geometry(geo(offset: 300, content: 1300, insetBottom: 90))) == .none)
        #expect(machine.handle(.geometry(geo(offset: 300, content: 1300, container: 400, width: 320, insetBottom: 90))) == .none)
        #expect(machine.state == .readingHistory)
    }

    @Test func prependWhileReadingRestoresTheRecordedAnchorOnce() {
        var machine = readingMachine(anchor: anchor("b", 20))
        #expect(machine.handle(.rowsChanged(["x", "a", "b", "c"])) == .restore(anchor("b", 20)))
        #expect(machine.handle(.geometry(geo(offset: 300, content: 1200, anchor: anchor("a", 5)))) == .none)
        #expect(machine.handle(.rowsChanged(["y", "x", "a", "b", "c"])) == .restore(anchor("b", 20)))
    }

    @Test func anchorStaysFrozenUntilTheAnchorRowIsBackOnTop() {
        var machine = readingMachine(anchor: anchor("b", 20))
        _ = machine.handle(.rowsChanged(["x", "a", "b", "c"]))
        _ = machine.handle(.geometry(geo(offset: 300, anchor: anchor("x", 7))))
        _ = machine.handle(.geometry(geo(offset: 320, anchor: anchor("b", 20))))
        _ = machine.handle(.geometry(geo(offset: 333, anchor: anchor("b", 33))))
        #expect(machine.handle(.rowsChanged(["w", "x", "a", "b", "c"])) == .restore(anchor("b", 33)))
    }

    @Test func prependWhilePinnedEmitsNothing() {
        var machine = ChatScrollMachine()
        _ = machine.handle(.rowsChanged(["a", "b"]))
        _ = machine.handle(.geometry(bottomGeo()))
        #expect(machine.handle(.rowsChanged(["x", "a", "b"])) == .none)
        #expect(machine.state == .pinnedToBottom)
    }

    @Test func appendWhileReadingCountsUnseen() {
        var machine = readingMachine(anchor: anchor("b"))
        #expect(machine.handle(.rowsChanged(["a", "b", "c", "d", "e"])) == .none)
        #expect(machine.unseen == 2)
        #expect(machine.handle(.rowsChanged(["a", "b", "c", "d", "e", "f"])) == .none)
        #expect(machine.unseen == 3)
    }

    @Test func appendWhilePinnedCountsNothing() {
        var machine = ChatScrollMachine()
        _ = machine.handle(.rowsChanged(["a"]))
        _ = machine.handle(.geometry(bottomGeo()))
        #expect(machine.handle(.rowsChanged(["a", "b"])) == .none)
        #expect(machine.unseen == 0)
    }

    @Test func replacedRowsKeepStateAndEmitNothing() {
        var reading = readingMachine(anchor: anchor("b"))
        #expect(reading.handle(.rowsChanged(["a", "b", "c2"])) == .none)
        #expect(reading.handle(.rowsChanged(["a", "b", "c2"])) == .none)
        #expect(reading.state == .readingHistory)
        #expect(reading.unseen == 0)
        var pinned = ChatScrollMachine()
        _ = pinned.handle(.rowsChanged(["a", "b"]))
        #expect(pinned.handle(.rowsChanged(["a", "b2"])) == .none)
        #expect(pinned.state == .pinnedToBottom)
    }

    @Test func jumpFromReadingScrollsThenPinsOnReachingTheBottom() {
        var machine = readingMachine(anchor: anchor("b"))
        _ = machine.handle(.rowsChanged(["a", "b", "c", "d"]))
        #expect(machine.unseen == 1)
        #expect(machine.handle(.jumpToNewest(animated: true)) == .scrollToBottom(animated: true))
        #expect(machine.state == .programmatic(.bottom))
        #expect(machine.unseen == 0)
        #expect(!machine.showsJumpButton)
        #expect(machine.handle(.geometry(geo(offset: 400))) == .none)
        #expect(machine.state == .programmatic(.bottom))
        #expect(machine.handle(.geometry(bottomGeo())) == .none)
        #expect(machine.state == .pinnedToBottom)
    }

    @Test func sendFromReadingScrollsThenPinsOnReachingTheBottom() {
        var machine = readingMachine()
        #expect(machine.handle(.send(animated: false)) == .scrollToBottom(animated: false))
        #expect(machine.state == .programmatic(.bottom))
        #expect(machine.handle(.geometry(bottomGeo(content: 1200))) == .none)
        #expect(machine.state == .pinnedToBottom)
        #expect(machine.unseen == 0)
    }

    @Test func programmaticBottomRepairsASizeChangeDisplacement() {
        var machine = readingMachine()
        _ = machine.handle(.jumpToNewest(animated: false))
        #expect(machine.handle(.geometry(geo(offset: 400, content: 1100))) == .scrollToBottom(animated: false))
    }

    @Test func sendAtTheBottomEmitsNothing() {
        var machine = ChatScrollMachine()
        _ = machine.handle(.geometry(bottomGeo()))
        #expect(machine.handle(.send(animated: true)) == .none)
        #expect(machine.handle(.jumpToNewest(animated: true)) == .none)
        #expect(machine.state == .pinnedToBottom)
    }

    @Test func revealScrollsToTheRowAndSettlesWhenItIsVisible() {
        var machine = readingMachine()
        #expect(machine.handle(.revealRow("r")) == .scrollToRow("r"))
        #expect(machine.state == .programmatic(.row("r")))
        #expect(machine.showsJumpButton)
        #expect(machine.handle(.geometry(geo(offset: 100))) == .none)
        #expect(machine.handle(.visibleRowsChanged(["q"])) == .none)
        #expect(machine.state == .programmatic(.row("r")))
        #expect(machine.handle(.visibleRowsChanged(["q", "r"])) == .none)
        #expect(machine.state == .readingHistory)
    }

    @Test func revealRetriesUntilVisible() {
        var machine = readingMachine()
        _ = machine.handle(.revealRow("r"))
        #expect(machine.handle(.revealRetry) == .scrollToRow("r"))
        _ = machine.handle(.visibleRowsChanged(["r"]))
        #expect(machine.handle(.revealRetry) == .none)
    }

    @Test func revealOfAnAlreadyVisibleRowSettlesOnTheNextRetry() {
        var machine = readingMachine()
        _ = machine.handle(.visibleRowsChanged(["r"]))
        #expect(machine.handle(.revealRow("r")) == .scrollToRow("r"))
        #expect(machine.handle(.revealRetry) == .none)
        #expect(machine.state == .readingHistory)
    }

    @Test func revealExhaustsAfterTheAttemptBudget() {
        var machine = readingMachine()
        _ = machine.handle(.revealRow("r"))
        var scrolls = 1
        for _ in 0..<(ChatScrollMachine.revealAttempts + 3) where machine.handle(.revealRetry) == .scrollToRow("r") {
            scrolls += 1
        }
        #expect(scrolls == ChatScrollMachine.revealAttempts)
        #expect(machine.state == .readingHistory)
        #expect(machine.handle(.revealRetry) == .none)
    }

    @Test func userScrollCancelsAReveal() {
        var machine = readingMachine()
        _ = machine.handle(.revealRow("r"))
        #expect(machine.handle(.userScrollBegan) == .none)
        #expect(machine.state == .readingHistory)
        #expect(machine.handle(.revealRetry) == .none)
    }

    @Test func userScrollCancelsRepairs() {
        var machine = ChatScrollMachine()
        _ = machine.handle(.geometry(bottomGeo()))
        for step in 1...ChatScrollMachine.maxRepairs {
            let content = 1000 + Double(step) * 100
            #expect(machine.handle(.geometry(geo(offset: content - 540, content: content))) == .scrollToBottom(animated: false))
        }
        #expect(machine.handle(.geometry(geo(offset: 760, content: 1400))) == .none)
        _ = machine.handle(.userScrollBegan)
        _ = machine.handle(.geometry(bottomGeo(content: 1400)))
        _ = machine.handle(.userScrollEnded)
        #expect(machine.state == .pinnedToBottom)
        #expect(machine.handle(.geometry(geo(offset: 860, content: 1500))) == .scrollToBottom(animated: false))
    }

    @Test func userScrollingOffTheBottomLeavesPinned() {
        var machine = ChatScrollMachine()
        _ = machine.handle(.geometry(bottomGeo()))
        _ = machine.handle(.userScrollBegan)
        #expect(machine.handle(.geometry(geo(offset: 200, anchor: anchor("b", 3)))) == .none)
        #expect(machine.state == .readingHistory)
    }

    @Test func userScrollEndedAtTheBottomPins() {
        var machine = readingMachine(anchor: anchor("b"))
        _ = machine.handle(.rowsChanged(["a", "b", "c", "d"]))
        _ = machine.handle(.userScrollBegan)
        _ = machine.handle(.geometry(bottomGeo()))
        #expect(machine.state == .readingHistory)
        #expect(machine.handle(.userScrollEnded) == .none)
        #expect(machine.state == .pinnedToBottom)
        #expect(machine.unseen == 0)
    }

    @Test func userScrollEndedAwayFromTheBottomReads() {
        var machine = ChatScrollMachine()
        _ = machine.handle(.geometry(bottomGeo()))
        _ = machine.handle(.userScrollBegan)
        _ = machine.handle(.geometry(geo(offset: 100)))
        #expect(machine.handle(.userScrollEnded) == .none)
        #expect(machine.state == .readingHistory)
    }

    @Test func readingReturnsToPinnedWhenTheBottomIsReached() {
        var machine = readingMachine()
        _ = machine.handle(.rowsChanged(["a", "b", "c", "d"]))
        #expect(machine.handle(.geometry(bottomGeo())) == .none)
        #expect(machine.state == .pinnedToBottom)
        #expect(machine.unseen == 0)
    }

    @Test func namesMatchTheTraceVocabulary() {
        #expect(ChatScrollMachine.State.programmatic(.bottom).name == "programmatic")
        #expect(ChatScrollMachine.Event.revealRetry.name == "revealRetry")
        #expect(ChatScrollMachine.Event.geometry(bottomGeo()).name == "geometry")
        #expect(ChatScrollMachine.Command.restore(anchor("a")).name == "restore")
        #expect(ChatScrollMachine.Command.none.name == "none")
    }
}

@Suite("Chat scroll machine bottom zone")
struct ChatScrollMachineBottomZoneTests {
    @Test func thresholdsLeaveADeadBandBetweenHideAndShow() {
        #expect(ChatScrollMachine.hideDistance < ChatScrollMachine.showDistance)
        #expect(ChatScrollMachine.atBottomTolerance < ChatScrollMachine.hideDistance)
    }

    @Test func wobbleInsideTheDeadBandNeverLeavesPinnedOrShowsTheButton() {
        var machine = ChatScrollMachine()
        _ = machine.handle(.geometry(bottomGeo()))
        for distance in [3.0, 30.0, ChatScrollMachine.showDistance, 12.0, 0.0] {
            #expect(machine.handle(.geometry(awayGeo(distance))) == .none)
            #expect(machine.state == .pinnedToBottom)
            #expect(!machine.showsJumpButton)
        }
    }

    @Test func pinnedLeavesOnlyBeyondTheShowDistance() {
        var machine = ChatScrollMachine()
        _ = machine.handle(.geometry(bottomGeo()))
        _ = machine.handle(.geometry(awayGeo(ChatScrollMachine.showDistance + 1)))
        #expect(machine.state == .readingHistory)
        #expect(machine.showsJumpButton)
        #expect(machine.distanceFromBottom == ChatScrollMachine.showDistance + 1)
    }

    @Test func buttonHidesOnlyAtTheHideDistanceOnTheWayDown() {
        var machine = readingMachine()
        #expect(machine.showsJumpButton)
        _ = machine.handle(.geometry(awayGeo(ChatScrollMachine.showDistance - 5)))
        #expect(machine.state == .readingHistory)
        #expect(machine.showsJumpButton)
        _ = machine.handle(.geometry(awayGeo(ChatScrollMachine.hideDistance + 1)))
        #expect(machine.showsJumpButton)
        _ = machine.handle(.geometry(awayGeo(ChatScrollMachine.hideDistance)))
        #expect(machine.state == .pinnedToBottom)
        #expect(!machine.showsJumpButton)
    }

    @Test func buttonFollowsTheDistanceWhileTheUserIsStillScrolling() {
        var machine = readingMachine()
        _ = machine.handle(.userScrollBegan)
        _ = machine.handle(.geometry(awayGeo(ChatScrollMachine.hideDistance + 1)))
        #expect(machine.showsJumpButton)
        _ = machine.handle(.geometry(awayGeo(ChatScrollMachine.hideDistance)))
        #expect(machine.state == .readingHistory)
        #expect(!machine.showsJumpButton)
        _ = machine.handle(.userScrollEnded)
        #expect(machine.state == .pinnedToBottom)
    }

    @Test func rubberBandPastTheBottomCountsAsAtTheBottom() {
        var machine = readingMachine()
        _ = machine.handle(.geometry(geo(offset: 560)))
        #expect(machine.distanceFromBottom == 0)
        #expect(machine.state == .pinnedToBottom)
        #expect(!machine.showsJumpButton)
    }

    @Test func userScrollEndedInsideTheDeadBandKeepsPinned() {
        var machine = ChatScrollMachine()
        _ = machine.handle(.geometry(bottomGeo()))
        _ = machine.handle(.userScrollBegan)
        _ = machine.handle(.geometry(awayGeo(40)))
        #expect(machine.handle(.userScrollEnded) == .none)
        #expect(machine.state == .pinnedToBottom)
        #expect(!machine.showsJumpButton)
    }

    @Test func userScrollEndedInsideTheDeadBandWhileReadingKeepsReading() {
        var machine = readingMachine()
        _ = machine.handle(.userScrollBegan)
        _ = machine.handle(.geometry(awayGeo(40)))
        _ = machine.handle(.userScrollEnded)
        #expect(machine.state == .readingHistory)
        #expect(machine.showsJumpButton)
    }

    @Test func sizeChangeInsideTheDeadBandStillRepairs() {
        var machine = ChatScrollMachine()
        _ = machine.handle(.geometry(bottomGeo()))
        #expect(machine.handle(.geometry(awayGeo(30, content: 1100))) == .scrollToBottom(animated: false))
        #expect(machine.state == .pinnedToBottom)
    }
}
