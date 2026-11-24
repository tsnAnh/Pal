#if os(macOS)
import Foundation
import PalChat

@testable import Pal

enum MacChatBenchFixture {
    static let messageCount = 200

    private static let questions = [
        "Can you check the failing deploy?",
        "ok",
        "What changed in the last release, and does it touch the billing flow? I need a short answer for the standup, but also the risky parts.",
        "thanks",
        "Summarise the open pull requests by owner and flag anything older than two weeks.",
        "Why is the nightly job slower than last week?",
        "yes please",
        "Draft the reply to the customer and keep it friendly but firm. Mention the refund window and the new support hours.",
    ]

    private static let shortReplies = [
        "Done.",
        "On it.",
        "Yes, that is fixed on main.",
        "Sure. Give me a minute.",
    ]

    private static let plainReply = """
    I looked at the deploy log and the failure comes from the migration step. The new column is declared \
    non-null with no default, so it fails on every table that already has rows. The fix is to add the column \
    as nullable, backfill it in batches, and only then add the constraint in a follow-up release. That keeps \
    the deploy safe to retry and avoids a long lock on the largest table.

    I have not changed anything yet. Tell me if you want the migration split or if you would rather freeze \
    writes for a few minutes and do it in one go.
    """

    private static let codeReply = """
    Here is the smallest change that fixes it:

    ```swift
    struct RetryPolicy {
        let attempts: Int
        let base: Duration

        func delay(for attempt: Int) -> Duration {
            let exponent = min(attempt, attempts)
            return base * Int(pow(2.0, Double(exponent)))
        }
    }

    func run<T>(policy: RetryPolicy, _ work: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await work() } catch {
                attempt += 1
                if attempt > policy.attempts { throw error }
                try await Task.sleep(for: policy.delay(for: attempt))
            }
        }
    }
    ```

    And the call site, which now reads `try await run(policy: .standard) { try await client.fetch() }`. \
    The jitter is intentionally left out so the tests stay deterministic.
    """

    private static let listReply = """
    ## Plan

    1. Reproduce the failure on a copy of the production snapshot.
    2. Add the nullable column and ship it behind the existing flag.
    3. Backfill in batches of 5,000 rows with a short pause between batches.
    4. Add the constraint once the backfill reports zero remaining rows.

    Things to watch while it runs:

    - Replication lag on the read replica, which should stay under two seconds.
    - Lock wait time on `orders`, which is the largest table.
    - The error budget for checkout, because a slow backfill can starve it.
      - If the budget drops below 90%, pause the backfill.
      - Resume once it recovers.
    """

    private static let tableReply = """
    The numbers for the last three runs:

    | Run | Duration | Rows | Result |
    | --- | --- | --- | --- |
    | Monday | 41 min | 1,204,332 | passed |
    | Tuesday | 58 min | 1,611,020 | passed |
    | Wednesday | 97 min | 2,998,114 | timed out |

    The duration grows faster than the row count, which points at the index rebuild rather than the copy itself. \
    Here is the quote from the owner of the job:

    > We will not raise the timeout again. Fix the rebuild or split the job.

    See the [runbook](https://example.com/runbook) and the **dashboard** for the full history, including `retry_count` per run.
    """

    private static let longReply = (0..<6).map { index in
        "Paragraph \(index + 1). The scheduler picks the next job by priority, then by age, then by owner, and it skips any job whose "
            + "dependencies have not finished. When two jobs share a resource the later one waits, which is why the queue looks idle "
            + "even though work is pending. This is intended, and it is the reason the nightly window is wider than the sum of the jobs."
    }.joined(separator: "\n\n")

    private static let replies = [shortReplies[0], plainReply, codeReply, shortReplies[1], listReply, tableReply, shortReplies[2], longReply, shortReplies[3]]

    static let streamedReply = [
        "## Investigation notes",
        longReply,
        codeReply,
        listReply,
        tableReply,
        plainReply,
    ].joined(separator: "\n\n")

    private static let imageReply = """
    The latency chart for the last release:

    ![latency chart](https://example.invalid/latency.png)

    It flattens after the fix.
    """

    static func world(streamingTail: Bool, messageCount: Int = MacChatBenchFixture.messageCount, images: Bool = false) -> RebuildWorld {
        var world = RebuildWorld()
        world.isRunning = streamingTail
        for index in 0..<messageCount {
            let date = rebuildAt(Double(index) * 95 + (index % 17 == 0 ? 4_000 : 0))
            if index.isMultiple(of: 2) {
                world.append(rebuildUser("u\(index)", questions[(index / 2) % questions.count], at: date))
            } else if images, index % 13 == 1 {
                world.append(rebuildAssistant("a\(index)", imageReply, at: date))
            } else {
                world.append(rebuildAssistant("a\(index)", replies[(index / 2) % replies.count], at: date))
            }
        }
        if streamingTail {
            world.append(rebuildAssistant("a-stream", "Looking into it now.", streaming: true, at: rebuildAt(Double(messageCount) * 95 + 4_000)))
        }
        return world
    }

    static func streamDelta(at index: Int, size: Int = 18) -> String {
        let characters = Array(streamedReply)
        let start = (index * size) % characters.count
        let end = min(start + size, characters.count)
        return String(characters[start..<end])
    }
}
#endif
