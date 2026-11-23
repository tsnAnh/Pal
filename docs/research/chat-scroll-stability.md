# Chat list stability: why it keeps jumping, and the design that ends it

Unit: chat-scroll-research. Base: main `0228552c`. Status: research. No scroll behaviour changes in this unit.

## Goal

The owner (part 278): "it still jumps down like this in the conversation list, the list is unstable and keeps jumping;
research the best way to fix this, this issue keeps getting fixed and never ends." The screenshot (Mac, Engineering
Manager chat) shows a long bubble whose last lines sit under the glass composer, with the jump-to-newest button
floating over the text. This is round six on the same symptom, so this note treats it as a design problem.

## Evidence level

The root cause and hypotheses below come from reading the code at `0228552c`, the six earlier pull requests, and
public sources. One measured trace now exists. See **Measured** below. It is one Release run of `40f10e88` on the
owner's Mac with `PAL_SCROLL_TRACE=1`: about 2 minutes, 1586 lines. The CSV sits on the Pi. This session worked
from the coordinator's summary of it and checked each claim against the code, not against the CSV rows.

## Root cause (by reading; trace pending)

The premise every round shared: the list can be made still by correcting the offset after something moved. That
premise is wrong for this list, for three structural reasons.

1. **The list is flipped, which puts the frequent growth on the side that moves what you read.** The scroll view and
   every row are drawn upside down with `scaleEffect(x: 1, y: -1)` (`apps/ios/App/Platform/ChatPlatform.swift:10-12`,
   applied at `App/Chat/ChatTranscriptList.swift:37`, `:117`, `:121`, `:132`, `:138`). Offset 0 is the newest message.
   In layout space the newest rows sit *above* the history you read. Streaming text, the working row, the
   footer, a new message and the composer inset all grow at the newest end, the most frequent changes there are.
   So while reading history, each of them pushes the visible rows. In a top-down list the same growth happens
   below the viewport and moves nothing. The flip trades this for free history paging, which happens rarely.
2. **The composer inset is mirrored by hand, one layout pass late.** Because the view is flipped, the system's
   bottom safe area (the composer) lands on the visual top. The list undoes that with
   `.contentMargins(.top, max(0, chrome.bottom - chrome.top) + ChatMetrics.composerClearance)` and
   `.contentMargins(.bottom, ...)` (`ChatTranscriptList.swift:34-35`), where `chrome` is `@State` written by
   `onGeometryChange(of: \.safeAreaInsets)` (`:14`, `:36`). The safe area changes in pass N and the margin follows in
   pass N+1. Every composer height change does this: typing a new line, a reply target, attachments, the usage banner
   and the error notice. The banner and the notice animate (`App/Chat/ChatView+Bottom.swift:84-85`), so the lag repeats
   every frame of the animation. The iPhone keyboard does it too.
3. **Three owners write the same offset, and the controller corrects after the fact.**
   - SwiftUI anchors on its own: `.scrollPosition($scroll.position)` with an id-typed `ScrollPosition` and
     `.scrollTargetLayout()` (`ChatTranscriptList.swift:32`, `:142`; `App/Chat/ChatScrollController.swift:44`).
     SwiftUI keeps the anchored row in place as rows change. The `swift-chat-scroll` lint docstring already relies
     on this (`scripts/ci/check_swift_chat_scroll.py:15-17`).
   - The controller writes six ways: open repin, anchor correction, visibility drift, keep-newest, jump and
     reveal (table below). Each runs after a geometry callback, so it lands on the next frame or later.
   - The system moves the offset through the safe area, the keyboard, content inset changes and window resize.

   Which owner wins depends on what wrote the position last. After a user scroll the position carries a view id, and
   SwiftUI anchors. After `scrollTo(y:)` or `scrollTo(edge:)` it carries a point, and SwiftUI does not. So the same
   streaming chunk can be corrected once, twice (overshoot) or not at all. Each fix so far removed one trigger inside
   this three-way fight, and the fight stayed.

### Hypotheses, ranked, with the trace signature for each

The trace (commit 2) writes one CSV line per geometry change, phase change, pin measurement, row change, chrome
change and controller write. `anchor` below is the pinned row's position relative to the newest-edge inset line:
`pin_min_y - distance`. A still list keeps it constant while the phase is idle.

| # | Hypothesis | Where | Trace signature |
|---|---|---|---|
| H1 | Composer or keyboard inset one pass late. In following mode a keep-newest write chases it. In reading mode nothing corrects it, so the last lines stay under the composer while the jump button shows. This matches the screenshot. | `ChatTranscriptList.swift:14`, `:34-36`, `:50`; `ChatScrollController.swift:219-225` (guard `mode == .following` at `:220`) | a `chrome` line whose `safe_bottom` changed, then a `geo` line with the old `inset_top`, an `anchor` step equal to the safe-area delta, then `keep-newest-chrome` (following) or nothing (reading) |
| H2 | Streaming growth while reading moves the visible rows, and `rowMoved` puts them back one frame later. That is a two-frame flicker per paced snapshot (16 ms, `PalChat/TimelinePacer.swift:5-24`), the "keeps jumping". The correction is skipped while the phase moves (`:159`) and while the chat is hidden (`:161-165`), so a flick during streaming leaves the shift in. | `ChatScrollController.swift:153-168`; `ChatPinProbe` `:277-289`; `ChatModel+StreamingPatch.swift:16-38` | `content_h` grows, `offset_y` unchanged, `anchor` steps by the growth, then an `anchor` write |
| H3 | Double anchoring. SwiftUI already kept the id-anchored row, and `rowMoved` adds the delta again, which overshoots. | `ChatTranscriptList.swift:32`, `:142`; `ChatScrollController.swift:166-167` | an `anchor` write followed by an `anchor` step of the opposite sign |
| H4 | Heights change after first layout above the viewport, in layout terms: a generated image swaps a 260 x 260/ratio placeholder for a 220 x 165 tile (`GeneratedImageRow.swift:55` vs `ChatImages.swift:140`, `:174`), a file card notice appears (`ChatFileCard.swift:77-82`), separators and the unread divider change with neighbours (`ChatModel.swift:796`), an empty streaming row is absent and then inserted (`ChatModelRows.swift:17-20`, used at `ChatModel.swift:795`), clarify answers merge (`ChatModel.swift:803`), and lazy rows are re-estimated. | as listed | a `rows` line or a `content_h` change without streaming, then an `anchor` step |
| H5 | The open repin dance writes `offset(0)` and then `newest` (`ChatScrollController.swift:116-133`), and `setVisible` replays drift (`:170-182`). | as listed | `open-pin` / `open-newest` / `drift` writes around a step |
| H6 | The #340 livelock guard drops a newest request while the distance is unchanged (`:228-233`). A dropped request waits for the next viewport move, so a following list can sit off the edge. | `ChatScrollController.swift:228-233` | a `skip` line for `keep-newest-*` while `distance > 0.5` and nothing after it |
| H7 | The hysteresis band. Following ends after a drag past 80 pt (`:110-111`) and resumes only within 24 pt (`:108`), both measured from the inset line. Between them the newest lines sit under the glass composer with the button shown, and every later change in H1 or H2 lands there uncorrected. | `ChatScrollController.swift:38-40`, `:108-111` | `mode=reading` with `0 < distance < safe_bottom` |

H1 and H7 together reproduce the screenshot with no other bug. H2 and H3 explain the repeated jumping. The trace
decides the ranking.

## Measured (owner's Mac, `40f10e88`, Release, one run)

The run went: open the Engineering Manager chat, scroll history, send while the bot streamed, resize the window,
switch chat. The first analyser counted 17 jumps at the 1 pt threshold. In the flipped list `offset_y = -inset_top`
is the newest edge, and `distance = offset_y + inset_top`. Line numbers are on this branch. The trace commit shifted
`ChatScrollController.swift` by a few lines from `0228552c`.

| t (s) | What the trace shows | Hypothesis | Writer in code | Real move? |
|---|---|---|---|---|
| 0.420; 102.18 (switch back) | open bounce: distance 0 → 35 → 0 (and 0 → 9 → 0). The geometry moved *before* any write, then `open-pin` and `open-newest` land 1 ms apart | H5 is the **repair**, not the cause. The displacement comes first, from first layout settling (H1 or H4) | repin `ChatScrollController.swift:116-133`. It fires only because `distance > 0.5` already (`:123`) | yes, one or two frames |
| 8.08 to 8.355 | send. The composer grows 103 pt (`inset_top` 92 → 195), rows 151 → 152 → 153, geometry `offset -107`, distance 88. `keep-newest-rows` applied, then `skip keep-newest-grew`, a one-frame overshoot to distance 479, back at 8.355 | H1 plus H6, plus two writes resolving in one pass (H3 shape, unproven) | keep-newest `:199`, `:204` → `:229`; the skip is the #340 guard `:233-237` | yes |
| 8.722 to 9.621 | displaced again (distance 172), and it **stays** displaced 0.9 s while the mode is following. It is restored only when rows change 153 → 149 | **H8 (new): following mode has no repair for a geometry-only displacement** | `observe` (`:97-114`) never calls `keepNewestInView`. `contentGrew` runs only when the content height grew (`ChatTranscriptList.swift:46`) or chrome changed (`:50`). The chrome path checks the distance from the *previous* geometry (`ChatScrollController.swift:225`), sees 0 and returns without a write. That path logs no trace line, only `PalPerf` `chat.scroll.position.skipped` | yes: the owner's "jumps down" |
| 21.603 to 21.614 | distance 0 → 89 → 0 within 2 ms with **no writer**, while `content_h` flips 32677 ↔ 33080 (403 pt) three times in 20 ms | layout oscillation: H3 (SwiftUI id anchoring) or H4 (a row whose height alternates). One guess is a width toggle reflowing a long message, which needs a width column to prove | none in app code | yes, two frames |
| 26.222, 28.556, 30.798 | reading mode: drifts of −3, −6, −6 pt while `content_h` grows 39265 → 44323 | H4 (heights refined above the viewport in layout terms), or H2 if a reply was streaming | the `rowMoved` correction `:155-171` lands a frame late, and is skipped while moving (`:162`) | yes, small |
| 53.777, 59.446, 64.362, 70.322, 76.32 (×2) | viewport unchanged (offset −92, inset 92, distance 0). `pin_min_y` goes 0 → 44 when one 44 pt row is appended, then the pin moves to the new row | none. **Analyser artefact** | the probe reports the *same* pinned row pushed 44 pt by the new newest row (`rowMoved` `:155`), then `visibleRowsChanged` (`:145-153`) re-pins. In following mode at the edge that push is the intended "new message appears" | no |

The 6 artefact lines are gone with the fixed analyser (finding D, below). That leaves **11 of the 17** as real
viewport moves: the open bounces, the send displacement and its 0.9 s hold, the layout oscillation, and three small
reading drifts. That count is an inference from the summary. It was not re-run on the CSV, which is not in this
session. Confirm it with `python3 apps/ios/Tools/perf/scroll_trace.py pal-scroll-trace.csv`. The fixed analyser
counts a bounce out and back as two viewport jumps.

**Finding D, corrected.** The coordinator's reading is right that these lines are not visible jumps. It is wrong about
the mechanism. The pin id does *not* change between the two flagged lines. The same pinned row really moved 44 pt
in content space, because a new row was inserted above it in layout (`ChatPinProbe`,
`ChatScrollController.swift:285-297`). The pin moves to the new row only on the next visibility callback. The
analyser change: in following mode only `distance` counts (a `viewport` jump). Rows growing at the newest edge while
the list stays at the edge are intended. The pinned-row test (an `anchor` jump) now applies only in reading mode, and
only between two lines with the same pin. The summary line reports `viewport=` and `anchor=` separately.

**Open bounce, one claim discarded.** The idea that `offset(0)` "ignores the 92 pt top inset" does not fit the code.
`open-newest` is written only after a geometry callback reports `distance <= 0.5` (`:128-130`). Two writes 1 ms
apart therefore mean `scrollTo(y: 0)` landed on the newest edge, so `scrollTo(y:)` is measured from the same
inset-adjusted origin as `distance`. Check it in the CSV: the `geo` line between the two writes should show
distance 0.

**What removed four rows at 9.621 s (153 → 149).** It is not the outbox echo. A pending row
(`submission:<id>`, `ChatModel.swift:741-746`) is replaced one-for-one by the timeline row with the same id
(`known`, `:729-732`; alias `:718-724`). Candidates, most likely first:
1. The live overlay settling into the stored turn. `Timeline.settleOverlay` drops live items once their stored entry
   binds (`PalChat/Timeline.swift:372-389`, `dropLiveItems` at `:387`), and the stored parts can be fewer than the
   live items they replace.
2. Folding into bot-thread links (`Timeline.fold`, `:584`, called from `rows(links:)` `:220`).
3. Clarify answers merging (`ChatModel.swift:803`).
4. Empty assistant rows filtered (`ChatModel.swift:795`).

The streaming reply itself is not a row while it streams (`Timeline.isShown`, `:575-581`). The trace logs only a row
count, so it cannot tell these apart. The next trace build should log counts per id prefix (`submission:`, `stream:`,
`row-`).

**Second chat, 53 to 76 s.** Rows grow 8 → 31 → 66 → 103 → 117 while `content_h` shrinks 21821 → 12623. This fits
the flip. Older pages append at the layout end far from the viewport, and LazyVStack replaces estimates with
smaller measured heights there. The newest edge does not move. Not a jump.

**Trace gaps for the next build.** Container width (for 21.6 s), the requested `y` of each write, a line for the
`keepNewestInView` stale-distance return (`:225-228`), and row counts per id prefix.

### The measurements against the options

| Signature | A (keep flip, one writer) | B (top-down, system anchors) | C (UIKit and AppKit lists) |
|---|---|---|---|
| open bounce (0.42 s, 102.18 s) | removes the repin pair. The first-layout displacement stays and needs one write | removes: `defaultScrollAnchor(.bottom)` sets the initial offset inside layout, with no repin | removes |
| send: composer +103 pt, overshoot (8.08 s) | removes only if the one writer reacts to inset changes with fresh geometry | removes: the bar is a system safe-area inset applied in the same pass, and `.sizeChanges` keeps the bottom | removes |
| 0.9 s hold off the edge (8.72 s, H8) | removes, if the machine repairs following mode on every geometry event (the missing transition) | removes: the system anchor follows the edge, with no app event needed | removes |
| layout oscillation, no writer (21.6 s) | leaves it | probably removes it if the flip or id anchoring is the cause. Not proven | removes, since layout is owned |
| reading drifts −3 / −6 pt (26 to 31 s) | leaves them (a correction a frame late) | moves them to the prepend case above the viewport. It depends on id anchoring, the known risk (FB20979569) | removes |
| artefacts (53 to 76 s) | n/a | n/a | n/a |

## Writers map

Every place that can change the transcript's offset, insets or position on `0228552c`. "Pass" means a SwiftUI
update and layout pass. A callback runs after the layout that produced it, so its write lands one pass later.

| Writer | file:line | Trigger | When, relative to layout | Races |
|---|---|---|---|---|
| `ScrollPosition` binding | `ChatTranscriptList.swift:32`, `ChatScrollController.swift:44` | user scroll updates it; every controller write sets it | during layout (SwiftUI) | all controller writes; SwiftUI's own id anchoring |
| SwiftUI id anchoring (`scrollTargetLayout`) | `ChatTranscriptList.swift:142` | rows change size or set while the position holds a view id | inside the layout pass | `rowMoved` anchor writes (H3) |
| top/bottom `contentMargins` from `@State chrome` | `ChatTranscriptList.swift:34-36` | safe area changes (composer, keyboard, banners, window) | one pass after the safe area changed | keep-newest; system keyboard and inset handling |
| top `safeAreaInset` banners (Teach, Auto-approve) | `ChatTranscriptList.swift:41-42` | banner appears or goes | same pass for the system inset; the mirrored margin follows one pass later | margins |
| composer `palSafeAreaBar` (`safeAreaBar` on iOS 26 and macOS 26, `safeAreaInset` on macOS 15) | `App/ChatView.swift:31`, `PalDesign/Components/PalSystemChrome.swift:87-102` | composer height | same pass (system) | margins (H1) |
| iPhone bar ignores the bottom container safe area (#342) | `App/ChatView.swift:43` | layout | same pass | changes what `chrome.bottom` measures |
| keyboard | system safe area; `.scrollDismissesKeyboard(.interactively)` at `ChatTranscriptList.swift:39` | keyboard show, hide, interactive drag | safe area per frame during the drag | margins; keep-newest skipped while the phase moves (`ChatScrollController.swift:220`) |
| `contentGrew()` on height growth | `ChatTranscriptList.swift:44-47` → `ChatScrollController.swift:206-212` → `keepNewestInView` `:219-225` | `contentHeight` grew | geometry callback, writes for the next pass | anchor, open repin |
| `contentGrew()` on chrome change | `ChatTranscriptList.swift:50` | `chrome` changed | the same update that applies the new margin | system inset changes |
| `rowsChanged` → keep-newest | `ChatTranscriptReaders.swift:9-12` → `ChatScrollController.swift:184-204` | row ids changed | `onChange` after the model update, before layout | contentGrew; anchor |
| open repin `offset(0)` then `newest` | `ChatScrollController.swift:116-133` (from `observe` `:97-114`) | open window, not at newest | geometry callback, two passes | keep-newest |
| `rowMoved` anchor correction `offset(distance + delta)` | `ChatScrollController.swift:153-168`; probe `:277-289` on the pinned row (`ChatTranscriptList.swift:133`) | pinned row's content minY moved while reading and idle | geometry callback of the row, so the next pass | SwiftUI id anchoring (H3); streaming |
| visibility drift replay | `ChatScrollController.swift:170-182`; `App/ChatView.swift:70-72` | chat appears again after drift accumulated | `onAppear` | keep-newest from the deferred sync |
| `jumpToBottom` (animated spring) | `ChatScrollController.swift:241-250`; button `ChatTranscriptList.swift:200-206`; send `ChatView+Bottom.swift:120`; image viewer `App/ChatView.swift:82` | user intent | immediate, animated over 0.35 s | every corrective write during the animation |
| find `reveal` (animated) plus up to 11 retries every 250 ms | `ChatScrollController.swift:252-265`; `ChatTranscriptReaders.swift:53-62` | find result | `Task` after `Task.yield()`, then sleeps | anchor writes; keep-newest is blocked by `revealing` only in `observe` |
| older paging | `ChatTranscriptReaders.swift:16-35` | `wantsOlder` (2 viewports from the oldest end) | `Task` every 250 ms, rows append at the old end | none in the flipped list (old end is below in layout) |
| jump button overlay | `ChatTranscriptList.swift:55-62` | mode | overlay only, no layout | none |
| composer `ScrollViewReader` | `App/Chat/ChatComposerParts.swift:22`, `:52` | suggestion list | its own scroll view | not the transcript |

No `NSScrollView`, `reflectScrolledClipView` or representable wraps the transcript in `App/`. On Mac, SwiftUI's
`ScrollView` is backed by an `NSScrollView`. The bench reaches it through the view tree
(`apps/ios/Tests/MacChatBenchSurface.swift`, `transcriptScrollView`).

## How the six earlier rounds fit

| PR | What it changed | Trigger it removed | What it left |
|---|---|---|---|
| #229 perf-streaming | `TimelinePacer.consume` applies at most one snapshot per 16 ms frame | per-delta rebuilds | growth still lands every frame, so H2 runs at up to 60 Hz while reading |
| #237 chat-open-no-jump | `ChatOpenGate` holds the cached paint until live or 300 ms; `chat.open.jump` signpost | cache paint followed by a live tail on open | the open repin writes (H5) and everything after open |
| #246 chat-list-no-left-shift | `containerRelativeFrame(.horizontal)` on iOS; `revealAnchor` x = 0; `swift-chat-scroll` lint | sideways offset from a centred anchor | vertical writers untouched |
| #340 Mac livelock | `write(_:)` skips a request the scroll view still owes | the two-request bounce inside one pass | a dropped request now waits for the next move (H6) |
| #341 footer as one row | working row and catch-up line live in one footer row | the stack re-estimating rows when footer rows came and went | footer height change at the newest end still pushes the rows while reading (H2 family) |
| #342 composer margin | iPhone bar ignores the bottom container safe area; Mac bottom margin 16 pt | the gap below the composer | the mirrored margin and its one-pass lag (H1) |

Each round removed one trigger inside the same structure. None changed the flip, the hand-mirrored inset, or the
fact that three owners write the offset.

## What the field does (sources)

These are public sources, read as data. Most are forum reports without an Apple fix. "Unverified" marks claims
from a snippet or a single report.

- **Bottom anchoring in SwiftUI.** `defaultScrollAnchor(_:for:)` takes `.initialOffset`, `.sizeChanges` and
  `.alignment` roles (iOS 18, macOS 15). https://useyourloaf.com/blog/swiftui-default-scroll-anchor/ ,
  https://fatbobman.com/en/posts/the-evolution-of-swiftui-scroll-control-apis/ . This repo already uses it in
  `App/Rooms/RoomView.swift:12`, `:53-55`.
- **Known problems with it.** iOS 26 (FB20979569): LazyVStack with variable-height rows plus `scrollPosition(id:)`,
  `scrollTargetLayout` and `defaultScrollAnchor(.bottom)` jumps, worst on keyboard show and hide. Fixed heights and
  iOS 18 are fine. https://developer.apple.com/forums/thread/805306 . iOS 27 single report: the anchor is
  reapplied on prepend and snaps to the newest row. https://developer.apple.com/forums/thread/848608
- **`ScrollPosition` precision.** Apple DTS says `scrollTo(id:)` is approximate, and that a point offset is not kept
  when the content size changes. https://developer.apple.com/forums/thread/799521
- **Writing `scrollTo(y:)` from `onScrollGeometryChange` fights the user's gesture,** and prepending with a
  `scaleEffect(y:-1)` flip also failed in the same report. https://developer.apple.com/forums/thread/781282 .
  `scrollTo` is ignored while the view is scrolling (unverified). https://developer.apple.com/forums/thread/838588
- **Flipped lists.** On iOS 18 a flip breaks `.contextMenu` placement. https://developer.apple.com/forums/thread/765290 .
  Flipping "opens a lot of issues (navbar jumping, pull to refresh, scroll indicator direction)".
  https://developer.apple.com/forums/thread/769695 . On iOS 26 an inverted list fades the nav bar from the wrong
  edge (reported with a rotation, so applicability is unverified). https://developer.apple.com/forums/thread/803130
- **Composer bars.** `safeAreaBar` (iOS 26) adjusts the safe area and lets the scroll edge effect run under the bar.
  https://developer.apple.com/documentation/swiftui/view/safeareabar(edge:alignment:spacing:content:) . A composer
  in `safeAreaInset` lags during interactive keyboard dismissal (unverified).
  https://developer.apple.com/forums/thread/801415 . A system-applied inset avoids this app's `@State` hop by
  construction. That is an inference.
- **Streaming coalescing.** Flush once per frame (https://dev.to/multigrid/streaming-tokens-into-a-react-ui-2g59).
  Stream recommends 5 to 20 updates per second for AI streaming (https://getstream.io/chat/docs/node/ai-message-streaming/).
  Pal already paces at the frame rate (#229).
- **Telegram iOS** rotates the list node 180 degrees and counter-rotates items on a custom `ListView`, which owns
  layout and offset itself. https://openaphid.github.io/2020-06-22-source-code-walkthrough-of-telegram-ios-part-6/ .
  Texture's inverted tables need manual inset adjustment. https://texturegroup.org/docs/inversion.html .
  Flipping works there because one component owns layout and offset.
- **UICollectionView chat layouts.** ChatLayout keeps the content at the bottom on batch updates
  (`keepContentOffsetAtBottomOnBatchUpdates`, `keepContentAtBottomOfVisibleArea`) and snapshots and restores an
  item plus edge offset (`getContentOffsetSnapshot`, `restoreContentOffset`).
  https://ekazaev.github.io/ChatLayout/Core.html . It is iOS only and has no AppKit twin. The standard UIKit
  recipe: record a visible cell's frame before the update, then add the delta to `contentOffset` inside layout.
  https://sergdort.github.io/collection-view-insert-in-front
- **AppKit.** NSTableView jumps on split-view resize (https://developer.apple.com/forums/thread/815217).
  Self-sizing rows grow but do not shrink (https://developer.apple.com/forums/thread/696976). Dynamic heights
  flicker on Sonoma (https://developer.apple.com/forums/thread/758302).
- **Not found:** Signal-iOS `ConversationViewController` scroll continuity, Element X, ExyteChat, MessageKit
  `maintainPositionOnKeyboardFrameChanged`, and the WWDC23 "Beyond scroll views" transcript. The next unit reads
  the repositories directly before it relies on them.

The pattern across the field: a still chat list has **one owner** of layout and offset that applies anchoring
**inside** the layout pass. Telegram's ListView, ChatLayout's invalidation, and SwiftUI's own
`defaultScrollAnchor` work that way. Pal's design corrects from callbacks after layout, and that is the class of bug.

## Options

| | A. Keep the flip, one writer | B. Top-down SwiftUI with system anchors (recommended, prototype-gated) | C. UICollectionView and NSTableView representables |
|---|---|---|---|
| Shape | Move every write into one PalKit state machine. Keep `scaleEffect` and the mirrored margins. Drop either SwiftUI id anchoring or `rowMoved`, not both. | Delete the flip. `defaultScrollAnchor(.bottom)` plus `.defaultScrollAnchor(.bottom, for: .sizeChanges)`, as `RoomView` does. Composer through `palSafeAreaBar` only, with no `chrome` state and no `contentMargins`. `scrollPosition(id:anchor: .bottom)` only for jump, reveal and the prepend anchor. The controller shrinks to mode, unseen and one prepend correction. | One `ChatListView` per platform owning layout and offset. Anchor applied in `prepare()` / `tile`. SwiftUI rows hosted in cells. |
| Removes | H5, H6 and double writes (H3). | H1 (system inset, same pass), H2 (streaming growth is below the viewport while reading, so no write is needed), H3, H5, H6, H7's uncorrected band (the system anchor follows the edge in layout). Also the VoiceOver reading-order risk of a flipped tree and the flip problems listed above. | All of them, at the cost of owning everything. |
| Leaves | H1 (the mirrored inset still needs the measured safe area, so there is still a hop) and H2 (streaming while reading still needs an after-the-fact correction). It shrinks the class without removing it. | Prepend (older pages) now happens above the viewport and needs anchoring. The iOS 26 variable-height jump report (FB20979569) is the main risk, and it must be benchmarked. | A new class of bugs in cell sizing, self-sizing invalidation and two platforms. |
| Cost | about 1 to 2 units: machine, migration, lint | about 2 to 3 units: prototype and bench, migration, lint, iPhone and Mac verify; deletes about 150 lines (`chrome`, margins, `ChatPinProbe`, `ChatPinSlots`, repin, drift, outstanding, flips) | about 6 to 10 units: two representables; re-home `SelectableTextView` (Mac TextKit sizing), hover bars, message menus, find reveal, drops, image viewer anchors, accessibility, the bench probes |
| Risk | low to ship; high that the symptom returns (round seven) | medium: prepend anchoring and the OS bugs above; mitigated by the bench gate | high: largest change, two platforms, regressions in text selection and accessibility |

**Recommendation after the trace: still B, gated by a prototype.** The trace backs the design reading. The largest
visible fault is not a bad write. It is a *missing* one: following mode has no transition for "geometry moved, rows
did not" (H8, 0.9 s displaced). That is the class B removes by construction, because the system anchor applies on
every layout, with no app event. B also removes the open bounce and the send displacement. It leaves one open risk:
the small reading drifts become prepend-above-viewport cases, and the prototype bench must show those still.
If they do not stay still, fall back to A's state machine on top of B's top-down geometry (one correction, prepend
only). C stays the escape hatch.

An interim option for the owner, not done in this unit: a one-line repair in `observe` that writes newest while
following and idle whenever `distance > 0.5`. It would remove H8, the 0.9 s hold, on today's flipped list. It
adds a seventh writer to the same fight, can bring back the #340 bounce, and leaves the drifts and the oscillation.
Recommended only if B cannot start soon.

## The design that removes the class

1. **One owner, one write path.** A pure `ChatScrollMachine` in PalKit (`Packages/PalKit/Sources/PalChat/`): a
   reducer `(State, Event) -> (State, [Command])`.
   - States: `pinnedToNewest`, `reading(anchor: RowAnchor)`, `programmatic(target, then:)`.
   - Events: `opened`, `rowsChanged(ids)`, `olderPrepended(ids)`, `userScroll(phase, distance)`, `jump`,
     `reveal(id)`, `visibility`.
   - Commands: `scrollTo(newest | row(id, anchor))`, applied by one view adapter.
   - Under B, streaming growth, composer, keyboard, rotation and window resize are not events at all. The system
     anchor handles them inside layout. That is the point.
2. **Anchor by row id plus offset,** never by absolute y. `RowAnchor(id, offsetFromViewportBottom)`, captured when
   reading starts and restored only on prepend.
3. **Composer inset in the same pass.** `palSafeAreaBar` only. Delete `@State chrome`, both `contentMargins` and the
   `onChange(of: chrome)`. The clearance becomes bottom padding on the newest row, or a `safeAreaPadding`, which is
   part of the same layout.
4. **Heights that do not change after first layout.** The generated-image placeholder reserves the final tile size
   (220 x 165, `ChatImages.swift`). The file-card notice reserves its line. The unread divider is an overlay, not
   a height change. Streaming stays paced by `TimelinePacer`. A measured-height cache is added only if the bench
   still shows LazyVStack re-estimates after B.
5. **Checks that fail on a jump.**
   - PalKit `ChatScrollMachineTests` (Swift Testing), one per transition: open, stream while pinned, stream while
     reading, older page while reading, new message while reading, jump, reveal, visibility, user scroll
     enter and leave.
   - Bench `MacChatScrollStressTests` (draft in commit 2, `apps/ios/Tests/`): the row-level jump probe of
     `MacChatOpenJumpTests` over two scenarios, a reply streaming 120 frames and then finishing while you read,
     and the composer growing to eight lines and shrinking while you read. Pass means no visible row moved by more
     than 1 pt with no user scroll. The remaining scenarios are in the harness spec below.
   - Trace replay: `apps/ios/Tools/perf/scroll_trace.py <csv> --max-jumps 0` fails a recorded scenario.
   - Lint `chat-scroll-single-writer`, a new rule in `scripts/ci/check_swift_chat_scroll.py` (already wired as
     `swift-chat-scroll` in `python scripts/check`). Under `App/Chat/**` and `App/ChatView.swift`, it forbids
     `\.scrollTo\(`, `ScrollPosition\(`, `\.scrollPosition\(`, `\.defaultScrollAnchor\(`, `\.contentMargins\(`,
     `\.safeAreaPadding\(` and `scaleEffect\(x: 1, y: -1` outside two files: the adapter
     (`ChatScrollController.swift`, which applies machine commands) and the list
     (`ChatTranscriptList.swift`, exactly one `.scrollPosition(` and the anchor modifiers). Opt-out on the
     line is `chat-scroll: ok`, as the rule already does. Its test in `tests/ci/test_check_swift_chat_scroll.py`
     fails on `0228552c` (the flip, the margins, the reveal writes) and passes after migration.

## Harness spec

Two harnesses already exist. The next units extend them instead of adding a third.

- **Mac bench, offscreen** (`apps/ios/Tests/MacChatBench*.swift`, `MacChatOpenJumpTests.swift`). It hosts the real
  `ChatTranscriptList` and composer in a hidden window, drives the backing `NSScrollView`, and samples every row's
  frame each 1/120 s through `OpenJumpProbe`. It runs in `PalTests` on a Mac with no gateway. Scenarios, with
  the state on `0228552c`:

  | Scenario | Probe check | State |
  |---|---|---|
  | open, live tail, older page at the newest edge | rows still | exists (`MacChatOpenJumpTests`) |
  | reading: older page, new tail rows, working row, catch-up line | rows still | exists (`MacChatOpenJumpTests`) |
  | reading: reply streams 120 frames, then finishes | rows still | commit 2 |
  | reading: composer grows to 8 lines, shrinks | rows still | commit 2 |
  | newest edge: composer grows | newest row's bottom stays above the composer's top | spec: needs the composer frame from the view tree |
  | newest edge: reply streams with a growing table and code block | newest row's bottom stays fixed | spec: fixture text with a table |
  | reading: generated-image placeholder becomes the image | rows still | spec: needs a `GeneratedImageRow` fixture |
  | reading: window resize | anchor row keeps its distance to the viewport bottom (text reflows, so not "rows still") | spec |
  | reading: older page lands while a reply streams | rows still | spec |

- **UI tests against the stub LLM** (`Tools/stub-llm/stub_llm.py`, `Scripts/e2e-gateway`, `UITests/`). The stub
  already streams `STREAM-LONG-MARKDOWN` (14 markdown sections at 12 ms per word piece, `stub_llm.py:56-59`,
  `:255-256`, `:303-347`) and `SLOW` (40 chunks every 0.25 s). The spec for a `SCROLLSTRESS` trigger: a constant near
  `stub_llm.py:56` and a branch near `:255` that streams paragraphs, a five-column table that grows row by row and a
  long code block, then calls a tool, so the working row comes and goes. A UI test modelled on
  `UITests/ChatListNoShiftE2ETests.swift` launches with `PAL_SCROLL_TRACE=1` and `PAL_PERF_DIR` (as
  `UITests/MacPerfTourTests.swift:17` does for `PAL_PERF`), sends the trigger, scrolls up one screen, waits for the
  stream to end, and fails when `scroll_trace.py --max-jumps 0` exits 1. iPhone adds the keyboard: focus the
  composer at the newest edge, then drag the list to dismiss it. The stub has no image trigger, so the image
  scenario stays on the bench.

## Unit split (after the owner picks)

| # | Unit | Tier | Depends on | Acceptance |
|---|---|---|---|---|
| 0 | Chief runs commit 2 on the owner's Mac: the bench suite and the trace over the manual script | chief | this PR | CSV and bench numbers per hypothesis |
| 1 | `ChatScrollMachine` plus tests in PalKit | Sonnet medium | 0 | every transition test green with `swift test` |
| 2 | Prototype B on a branch, with the bench scenarios as the gate | Sonnet high | 1 | bench zero jumps on macOS 15 and 26, iPhone simulator verify-ios; or a written fail that triggers the fallback |
| 3 | Migrate: delete the flip, `chrome`, margins, `ChatPinProbe`/`ChatPinSlots`, repin, drift and outstanding; wire the machine | Sonnet high | 2 | bench green, `ChatScrollControllerTests` rewritten around the machine, `MacChatOpenJumpTests` and `MacChatScrollLivelockTests` green |
| 4 | Fixed placeholder heights (generated image, file card notice, divider) | Sonnet medium | 3 | bench image-late scenario zero jumps |
| 5 | Lint `chat-scroll-single-writer` plus the AGENTS.md Rule 6 row | Sonnet medium | 3 | lint fails on `0228552c`, passes after |
| 6 | Owner verify on Mac and iPhone with the manual script below | owner | 3 to 5 | no jump in any scenario |

## What CI can and cannot check

- CI builds the app and test bundles (`xcodebuild build-for-testing`, `.github/workflows/python.yml:259`, `:270`) but
  runs no Swift tests. A compile error in commit 2 shows up there. Nothing else does.
- `python scripts/check` runs the Python lints, including `swift-chat-scroll` and `swift-perf`.
- `scripts/run_tests.sh tests/scripts/test_scroll_trace.py` runs the trace analyser test.
- The PalKit machine tests, the Mac bench and the trace need a Mac. The chief runs them.

## Manual script (owner, Mac and iPhone)

Run with `PAL_SCROLL_TRACE=1` (Mac: `PAL_SCROLL_TRACE=1 /Applications/Pal.app/Contents/MacOS/Pal`; iPhone: the Xcode
scheme environment). The CSV lands in `PAL_PERF_DIR` or the app's temporary directory as `pal-scroll-trace.csv`.
Analyse it with `python3 apps/ios/Tools/perf/scroll_trace.py <csv>`. Use a long chat such as Engineering Manager.

1. Open the chat cold. Wait 3 s. Expected: one paint, no movement.
2. Send STREAM-LONG-MARKDOWN (the stub trigger) or ask for a long answer with a table and code. Stay at the newest
   edge. Expected: the last line stays just above the composer the whole time.
3. While it streams, scroll up one screen and let go. Expected: the text you read does not move.
4. Scroll up slightly (about 40 pt) so the last line is just under the composer. Expected: the jump button appears
   only once the last line is fully hidden, and nothing moves by itself.
5. While reading, type three lines into the composer and delete them. Expected: the history does not move.
6. At the newest edge, type three lines. Expected: the last message rises with the composer and stays fully visible.
7. Scroll to the top until older history loads. Expected: the row under your eye stays.
8. While reading, receive a new message from another device. Expected: no movement, the button shows a count.
9. Find (Cmd-F on Mac) a word in an old message. Expected: one smooth move to it.
10. Mac: resize the window narrower and wider while reading. iPhone: rotate. Expected: the row under your eye stays.
11. iPhone: open the keyboard at the newest edge, then drag it down interactively while reading.
12. Ask for an image or attach a file in a long chat, then scroll away and back.

Record the macOS version, because the composer path differs between 15 (`safeAreaInset`) and 26 (`safeAreaBar`).

## Open questions for the owner (recommended answers)

1. Which option? Recommended: **B, gated by the prototype bench**, with A's state machine as the fallback.
2. While you read history and a reply streams in, should the list stay still or follow? Recommended: **stay still**,
   with the jump button showing a count, as today's intent (`ChatScrollController.swift:200-203`).
3. When should the jump button appear? Recommended: **only when the newest message's last line is fully hidden
   under the composer.** Today it appears after an 80 pt drag and stays until within 24 pt (H7).
4. Sending while reading jumps to the newest message. Keep? Recommended: **keep** (`ChatView+Bottom.swift:120`).
5. Which macOS version is the screenshot from (15 or 26)? This decides which composer path to test first.
6. Did the screenshot follow a small upward scroll, or appear on its own while a reply streamed? This separates H7
   from H1 and H2 before the trace arrives.
7. Ship the interim `observe` repair for H8 before B lands? Recommended: **no, unless B cannot start this week.** It
   adds a writer, and the trace shows the writers are the problem.
