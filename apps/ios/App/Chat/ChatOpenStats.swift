import PalChat

struct ChatOpenStats {
    let openedAt = ContinuousClock.now
    var source = ChatOpenCounters.Source.none
    var rowsAtStart = 0
    var counters: ChatOpenCounters?
    var hasShownRows = false
    var clearedAfterData = false
    var snapshotFromEarlierRun = false
    var heights: ChatRowHeightFile?
}
