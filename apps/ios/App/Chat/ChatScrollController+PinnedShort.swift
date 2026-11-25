import PalChat
import PalDiagnostics
import SwiftUI

extension ChatScrollController {
    var pinnedButShortCount: Int { pinnedShort.episodes }

    func watchPinnedShort(distance: Double) {
        pinnedShort.note(pinned: machine.state == .pinnedToBottom, distance: distance, atMilliseconds: Self.nowMilliseconds)
        guard pinnedShort.isShort, pinnedShortCheck == nil else { return }
        pinnedShortCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(ChatPinnedShortWatch.limitMilliseconds) + 1))
            guard let self else { return }
            pinnedShortCheck = nil
            guard let episode = pinnedShort.overdue(atMilliseconds: Self.nowMilliseconds) else { return }
            Diagnostics.osLog().notice("chat.scroll", "pinned_but_short distance=\(Int(episode.distance)) ms=\(episode.milliseconds)")
        }
    }

    func releaseEdgeOnceAtBottom() {
        guard edgeIsArmed, !isResizing, machine.state == .pinnedToBottom,
              (machine.distanceFromBottom ?? .infinity) <= ChatScrollMachine.atBottomTolerance
        else { return }
        edgeIsArmed = false
        Task { @MainActor [weak self] in
            guard let self, !edgeIsArmed else { return }
            position = ScrollPosition(idType: String.self)
        }
    }

    private static var nowMilliseconds: Double { Double(LaunchClock.elapsedMilliseconds) }
}
