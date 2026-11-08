# Bot chat turn

The user opens a bot, types a message, and watches the reply stream in. The bot can ask a clarifying question with choices. Messages sent while the gateway is down are queued and delivered once after it returns. A chat reopened later starts at the newest message.

## Sub-features

- `chat-send-stream` sends a message and streams the reply into one assistant bubble.
- `chat-clarify` shows a clarify card with choices and also accepts a typed answer from the composer.
- `chat-relaunch-midstream` keeps exactly one reply when the app is killed and relaunched mid-stream.
- `chat-offline-queue` shows a reconnecting indicator, queues a send, and delivers it exactly once after recovery.
- `chat-dynamic-type` keeps roster and clarify card usable at extra-large text.
- `chat-reopen-bottom` reopens a long chat at the newest message without scrolling.

## How to get to it (user POV)

- Sign in, tap a bot row in the roster, type in `Message <bot>` and tap Send.
- Reopen a bot from the roster after relaunching the app.

## Driving it with verify-ios

Preconditions:

- `$S/doctor` is all `PASS`.

- **Send and stream** (`chat-send-stream`). Run `$S/drive --label chat-send-stream BotChatE2ETests/test2SendStreamsReply`. The test opens `botRow-bot-beta`, types `hello beta` into `composerField`, taps `sendButton`, waits for one `userBubble` containing the text and an `assistantBubble` containing `stub-`. Result `verdict=PASS`; `chat-reply.png` shows both bubbles. Side effects: `fake-llm-requests.jsonl` contains a user message `hello beta`; `sandbox-db-messages.txt` shows `bot-beta` rows with roles `user` and `assistant`.
- **Clarify** (`chat-clarify`). Run `$S/drive BotChatE2ETests/test3ClarifyCardAndComposerAnswer`. The prompt `CLARIFY pick one` shows `clarifyCard` with `Which flavor do you want?`; tapping `clarifyChoice-0` completes the turn with `"user_response": "vanilla"`; a second question answered from the composer with `chocolate` completes without adding a user bubble.
- **Relaunch mid-stream** (`chat-relaunch-midstream`). Run `$S/drive BotChatE2ETests/test4RelaunchMidStreamKeepsOneReply`. The app is terminated while `assistantBubble-streaming` exists, relaunched, and ends with one user bubble and one `slow-` reply.
- **Offline queue** (`chat-offline-queue`). Run `$S/drive-control BotChatE2ETests/test5OfflineSendDeliversOnce`. After `kill-gateway`, `reconnectingIndicator` shows; sending `OFFLINE-PING-7731` shows `deliveryQueued`; after `start-gateway` the queued state clears and the sandbox DB holds exactly one such user message (`db-count.txt` total=1).
- **Dynamic type** (`chat-dynamic-type`). Run `$S/drive BotChatE2ETests/test6DynamicTypeExtraLarge`. Read `roster-dynamic-type-xl.png` and `chat-clarify-dynamic-type-xl.png` for clipped or overlapping text.
- **Reopen long chat** (`chat-reopen-bottom`). Run `$S/drive BotChatE2ETests/test7ReopenLongChatStartsAtBottom` (about 14 turns, a few minutes). The newest user message is hittable at first appearance and the oldest is not.
- **Proof.** For any chat drive, `run.mov` plus `shots/` show the typed message and the streamed reply, and the fake LLM and DB artifacts confirm the turn reached the gateway.

## Gotchas

- Fake LLM replies are `stub-00 stub-01 ...`. Assert on the `stub-` prefix, not on real text.
- `SLOW` makes the stream last about 10 s; the stream and relaunch test depend on it.
- `test5` and the live-roster tests need `drive-control`; `drive` has no control channel and fails with `HERMES_UITEST_CTL not set`.
- `userBubble` and `assistantBubble` are matched by label `CONTAINS`; a long history makes substring matches ambiguous, so use unique text like `history-07`.
- Tests share the sandbox DB across a run. Counts such as `total=1` in `db-count.txt` are only valid within one `drive-control` invocation, which makes a fresh gateway.
