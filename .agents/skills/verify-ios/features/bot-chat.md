# Bot chat turn

The user opens a bot, types a message, and sees a thinking row until the whole reply lands at once. The bot can ask a clarifying question with choices, and the answered card stays in the chat. A long chat opens at the newest message and follows new replies. Messages sent while the gateway is down are queued and delivered once after it returns.

## Sub-features

- `chat-send-reply` sends a message and shows one user bubble, a thinking row, then one assistant bubble with the whole reply.
- `chat-reply-whole` never shows a partial reply: the thinking row stays up until the reply is complete.
- `chat-clarify` shows a clarify card with choices and a Skip, also accepts a typed answer from the composer, and keeps the answered card (no raw JSON) after the turn and after relaunch.
- `chat-relaunch-midstream` keeps exactly one reply when the app is killed and relaunched mid-turn.
- `chat-offline-queue` shows a reconnecting indicator, queues a send as `Queued, will send when online` with a retry, and delivers it exactly once after recovery.
- `chat-dynamic-type` keeps roster and clarify card usable at extra-large text.
- `chat-reopen-bottom` reopens a long chat at the newest message without scrolling.
- `chat-follow-new-reply` scrolls a new reply into view in a long chat, above the composer.
- `chat-find` searches the transcript from the chat menu, highlights matches, and steps through them with a counter. Needs the parity seed.
- `chat-bot-thread` folds bot-to-bot exchanges into a link row (`4 messages with <bot>`) that opens a read-only thread on both the sending and receiving bot. Needs the parity seed.
- `chat-attach` attaches a photo from the library and sends it with a caption. Needs the parity seed.
- `chat-voice` opens voice mode and closes it; `chat-dictation` starts dictation or explains why not. Needs the parity seed.
- `chat-slash-picker` opens a picker of gateway commands and skills when the draft starts with `/`. No shipped UI test.
- `chat-hidden-rows` hides `[SILENT]` replies, cron-job turns and process-completion rows from the transcript (`TranscriptVisibility.swift`). No shipped UI test.
- `chat-reply-react` long-presses a message for a menu with reactions and `Reply` (`contextReply`, `replyBar`, `messageReaction`). No shipped UI test on iOS.

## How to get to it (user POV)

- Sign in, tap a bot row in the roster, type in `Message <bot>` and tap Send.
- Reopen a bot from the roster after relaunching the app.
- In a chat, the overflow menu holds Find in chat, View Profile and Share as Template; the paperclip attaches photos; the mic dictates; the voice button opens voice mode.

## Driving it with verify-ios

Preconditions:

- `$S/doctor` is all `PASS`.
- `chat-find`, `chat-bot-thread`, `chat-attach`, `chat-voice` and `chat-dictation` need `VERIFY_IOS_SEED=parity $S/launch` (a roster of eight parity bots replaces `bot-alpha` and `bot-beta`). Their classes skip without it and a skip is a failed proof.

- **Send and reply** (`chat-send-reply`). Run `$S/drive --label chat-send-reply BotChatE2ETests/test2SendStreamsReply`. The test opens `botRow-bot-beta`, types `hello beta` into `composerField`, taps `sendButton`, waits for one `userBubble` containing the text and an `assistantBubble` containing `stub-`. Result `verdict=PASS`; `chat-reply.png` shows both bubbles. Side effects: `fake-llm-requests.jsonl` contains a user message `hello beta`; `sandbox-db-messages.txt` shows `bot-beta` rows with roles `user` and `assistant` (counts per role, not message text).
- **Reply appears whole** (`chat-reply-whole`). Run `$S/drive --label chat-reply-whole BotChatPresentationE2ETests/test4ReplyAppearsWholeAfterThinking`. After a `SLOW` prompt the test samples the transcript for up to 90 s: a `Thinking` row (`assistantBubble-streaming`) is seen at least 5 times, no `slow-` text appears in it, and the first `assistantBubble` below the user bubble already contains `slow-00` and `slow-39`. `chat-reply-whole.png` is the final frame.
- **Clarify** (`chat-clarify`). Run `$S/drive BotChatE2ETests/test3ClarifyCardAndComposerAnswer`. The prompt `CLARIFY pick one` shows `clarifyCard` with `Which flavor do you want?` and `Or answer in the chat below`; tapping `clarifyChoice-0` completes the turn with `Got it, vanilla`, the interactive card goes and a `clarifyAnswered` card stays; a second question answered from the composer with `chocolate` completes without adding a user bubble. Then `$S/drive BotChatPresentationE2ETests/test3AnsweredClarifyStaysOnScreenWithoutRawJSON` picks `clarifyChoice-1`, checks the answered card shows the question and the pick with no raw JSON bubble, relaunches and checks it is still there.
- **Relaunch mid-turn** (`chat-relaunch-midstream`). Run `$S/drive BotChatE2ETests/test4RelaunchMidStreamKeepsOneReply`. The app is terminated while the thinking row (`assistantBubble-streaming`) exists, relaunched, and ends with one user bubble and one `slow-` reply.
- **Offline queue** (`chat-offline-queue`). Run `$S/drive-control BotChatE2ETests/test5OfflineSendDeliversOnce`. After `kill-gateway`, `reconnectingIndicator` shows; sending `OFFLINE-PING-7731` shows `deliveryQueued`; after `start-gateway` the queued state clears and the sandbox DB holds exactly one such user message (`db-count.txt` total=1).
- **Dynamic type** (`chat-dynamic-type`). Run `$S/drive BotChatE2ETests/test6DynamicTypeExtraLarge`. Read `roster-dynamic-type-xl.png` and `chat-clarify-dynamic-type-xl.png` for clipped or overlapping text.
- **Reopen long chat** (`chat-reopen-bottom`). Run `$S/drive BotChatE2ETests/test7ReopenLongChatStartsAtBottom` (14 turns, a few minutes). The newest user message is hittable at first appearance and the oldest is not.
- **Follow new reply** (`chat-follow-new-reply`). Run `$S/drive BotChatE2ETests/test8NewReplyInLongChatScrollsIntoView` (11 turns). The newest reply contains `slow-39`, is hittable and ends above `composerField`; `chat-long-new-reply.png`.
- **Find in chat** (`chat-find`). With the parity seed, run `$S/drive --label chat-find SeededChatE2ETests/test1FindInChatHighlightsAndStepsThroughMatches`. `chatMenuButton` opens the menu (`chatMenuFind`, `chatMenuViewProfile`, `chatMenuShareTemplate` exist); typing `igloo` into `findField` gives `findCount` `2 of 2`, `findPrevious` gives `1 of 2`, a nonsense word gives `No results`, `findDone` returns the composer.
- **Bot-to-bot thread** (`chat-bot-thread`). With the parity seed, run `$S/drive SeededChatE2ETests/test7BotToBotLinkOpensTheReadOnlyThreadAtTheTappedExchange SeededChatE2ETests/test8ReceivingSideShowsItsOwnLinkAndTheSameThread`. `botThreadLink` reads `4 messages with Market Researcher` on `cho-research-app` and `4 messages with chó research app` on `market-researcher`; the thread has `threadReadOnlyPill`, no composer, and shows the reply `7.1/10`.
- **Attach, voice, dictation** (`chat-attach`, `chat-voice`, `chat-dictation`). With the parity seed, run `$S/drive SeededChatE2ETests/test4PhotoLibraryAttachmentIsSent` (needs a photo in the simulator library), `.../test5VoiceModeOpensAndCloses` and `.../test6DictationStartsOrExplainsWhyNot`. Dictation passes when the mic listens or the `Dictation unavailable` alert explains why.
- **Hidden rows and the inbound notice** (`chat-hidden-rows`). `SeededChatE2ETests/test2InboundBotRowsAreNotHumanBubbles` still expects a `Background task finished` notice row that `TranscriptVisibility.swift` now hides, so it fails on main. That is a product or test gap, not drift in this map.
- **Proof.** For any chat drive, `run.mov` plus `shots/` show the typed message and the reply, and the fake LLM and DB artifacts confirm the turn reached the gateway.

## Gotchas

- Fake LLM replies are `stub-00 stub-01 ...`. Assert on the `stub-` prefix, not on real text.
- Replies are not streamed to the screen. `assistantBubble-streaming` is the thinking row, not partial text.
- `SLOW` makes the turn last about 10 s; the relaunch and whole-reply tests depend on it.
- `test5` and the live-roster tests need `drive-control`; `drive` has no control channel and fails with `HERMES_UITEST_CTL not set`.
- `userBubble` and `assistantBubble` are matched by label `CONTAINS`; a long history makes substring matches ambiguous, so use unique text like `history-07`.
- Tests share the sandbox DB across a run. Counts such as `total=1` in `db-count.txt` are only valid within one `drive-control` invocation, which makes a fresh gateway.
- `sandbox-db-messages.txt` holds per-role message counts (`scripts/drive`), not message text; read text from `fake-llm-requests.jsonl`.
- The seeded classes skip unless the run was launched with `VERIFY_IOS_SEED=parity`; the seeded gateway has no `bot-alpha` or `bot-beta`, so the default-seed tests then fail. Use one seed per run.
