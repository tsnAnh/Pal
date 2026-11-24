struct ChatOpenStats {
    let openedAt = ContinuousClock.now
    var hasShownRows = false
    var clearedAfterData = false
    var snapshotFromEarlierRun = false
}
