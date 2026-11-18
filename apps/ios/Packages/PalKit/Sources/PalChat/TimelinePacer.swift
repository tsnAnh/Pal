import Foundation
import PalDiagnostics

public enum TimelinePacer {
    public static let frame = Duration.milliseconds(16)

    public static func consume(
        _ snapshots: AsyncStream<TimelineSnapshot>,
        pause: () async -> Void = { try? await Task.sleep(for: TimelinePacer.frame) },
        isolation: isolated (any Actor)? = #isolation,
        apply: (TimelineSnapshot) -> Void
    ) async {
        var lastVersion: UInt64?
        for await next in snapshots {
            if let lastVersion, next.version > lastVersion + 1 {
                PalPerf.event("chat.snapshot.coalesced", count: Int(next.version - lastVersion - 1))
            }
            lastVersion = next.version
            apply(next)
            await pause()
        }
    }
}
