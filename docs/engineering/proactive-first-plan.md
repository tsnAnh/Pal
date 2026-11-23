# Proactive first: step 1 decision note

Step 1 builds and runs the instruments. It merges no behaviour change. Step 2, a separate unit after the owner decides, implements the principle. The definition and the owner choices are in [proactive-first.md](proactive-first.md).

**How to read the labels.** Every claim carries one of three labels.

- **Read from code.** A file and line, read in this checkout. It says what the code does, not what the owner experiences.
- **Synthetic.** Measured on invented fixtures in this repo. It proves the machinery works. It is not evidence about real bots.
- **Pending on the Pi.** Needs the real session store. The chief or the owner runs the same instrument read-only and brings back counts.

## 1. What the code and prompts say today (read from code)

| Where | What it does |
|---|---|
| `agent/prompt_builder.py:397-419` | `OWNER_PROACTIVE_GUIDANCE`. Decide on a loose request and state the assumption. Bring one recommended option with the result prepared. Ask only owner-only, irreversible or paid items, batched with a recommended answer. Never ask what files, history, the web, tools, chat or memory hold. Stuck: try other routes, never hand work back. The approval gate wins. |
| `agent/system_prompt.py:578` | Injects the block first in `_guidance_parts`, before the tool-gated blocks, so a toolless one-shot gets it too. It sits in the stable tier. |
| `agent/prompt_builder.py:385-395` | `TASK_COMPLETION_GUIDANCE`. Line 392 tells a failing bot to try "different package manager, different approach, ask the user". This contradicts line 413 of the principle block ("never hand your owner your stuck work"). Baseline finding, see section 6. |
| `agent/prompt_builder.py:330` | Kanban guidance says to ground an assignee in a real profile, "or ask the user". The first route is a lookup, so this is mild. |
| `tools/clarify_tool.py:168-232` | The schema. Description line 170 opens with "Ask the user one or more questions when you need a decision or feedback". Lines 171-175 carry the two-bubble rule (details as a normal message, then ONE short question line and options only). Lines 191-193 say "Prefer deciding low-stakes questions yourself". Options are capped (`MAX_CHOICES = 4`, `OPTION_MAX_CHARS`), the first option is marked recommended, up to `MAX_QUESTIONS = 5` independent questions go in one call. |
| `agent/prompt_builder.py:401-402` | The block caps a proposal at "one recommended option ... plus at most one alternative". The owner's second principle (offer choices) needs this relaxed, see section 7. |
| `tools/clarify_tool.py:55-96`, `:184` | `_normalize_questions` treats `choices` as optional (`:70`) and the description allows "open-ended (omit choices)". A question with no options and no suggested default is legal today. The tool caps options at `MAX_CHOICES = 4` (`:80`), marks the first one `(Recommended)` (`:13`) and the UI adds an "Other" row. |
| `tools/bot_mode_probe.py:299-330` | The Bot Mode house style. It already asks for one ready recurring routine "as a single yes or no" after a task that will recur. |
| `tools/bot_mode_probe.py:352-366` | `_own_job_paragraph`. A bot with no job is told to propose the job its name and role imply and ask the owner to confirm. This is the per-bot profile text. The profile `SOUL.md` is the other per-bot surface. |

The principle block is present once in the stable tier of all nine committed surfaces (synthetic check against the committed prompt-surface snapshot, run in CI by `tests/agent/test_proactive_first_prompt_surface.py`).

## 2. System mechanisms and what is missing (read from code)

| Mechanism | What it does today | Limit |
|---|---|---|
| `hermes_cli/proactive_cmd.py:14-161` | `hermes proactive` and `/reach`. Show status, `on`/`off` (`:68`), `mute`/`unmute` a domain (`:75`), `log [7d]` (`:116`) lists offers with their outcome. | Control and audit only. It starts nothing. |
| `hermes_cli/config_defaults.py:1749-1757` | `proactive.enabled: False`, `daily_budget: 3`, `min_gap_minutes: 60`, quiet hours 22:00 to 08:00, tiers `cron: notify`, `suggestions: suggest`, `messaging_window_minutes: 30`. | Off by default. |
| `gateway/reach_policy.py:13-19`, `:151-164` | Policy defaults and `load_policy`. | Only `enabled is True` turns Hermes-initiated alerts on. |
| `gateway/reach_policy.py:167-189` | `judge`. A muted domain lands silently. An alert the owner requested always passes. An alert Hermes initiated needs `enabled`, a tier that allows the kind (`notify` allows `NOTIFY`; `suggest` or `notify` allows `SUGGEST`), fewer than `daily_budget` alerts in 24 hours, and `min_gap` since the last. Quiet hours defer to the end of the window. | This is the owner-away boundary. Within it a bot may alert; outside it the offer lands silently or defers. |
| `gateway/reach_policy.py:192-194` | `rank`. Parked routes are dropped; the rest sort by attention, then last input. | |
| `gateway/reach_presence.py:7-8`, `:101-107` | `ENGAGED_WINDOW_SECONDS = 300`, `SILENT_TRANSPORT_SECONDS = 45`. A transport silent for 45 seconds is parked. Input within 5 minutes or a foreground app is engaged. | Defines "owner away" at the device level. |
| `gateway/reach.py:248-285` | `offer`. Claims the offer, lands it in the durable lane (chat or Bot Chat session), then alerts the best live route (app socket or a messaging platform, `:182`, `:204`, `:219`). `drain_deferred` (`:287`) resumes deferred offers. | It delivers an offer. It does not decide to make one. |
| Offer producers | `cron/scheduler_delivery_reach.py:45-62` (a cron job's output; consent `REQUESTED` when the job was user-created, else `INITIATED`) and `cron/suggestions.py:133-139` (a suggested job, `INITIATED`, backlog capped at `MAX_PENDING = 5` on `:37`). | Only these two exist. Nothing offers a bot's own follow-up on its own task. |
| `plugin-catalog/proactive-continuity.yaml:6` | Community plugin. Adds working rules to the prompt, lists open Kanban cards at session start, sends a continue message when a turn ends with work remaining (at most 6 per session per hour, needs `allow_gateway_injection`), routes sends and payments to the approval gate. | A catalog entry, not core. Installed or not on the Pi is pending. It keeps a bot working inside a session, not across the owner's absence. |
| `plugin-catalog/hermes-proactive-radar.yaml:8` | Community plugin. Follows mail, calendar, GitHub and the owner's chats as long-lived tasks and writes first, only when something is the owner's to decide. Sending email always asks. Installed disabled and in shadow mode. Reads private accounts. | A catalog entry. A credentials and privacy decision for the owner. Not recommended before B is measured. |
| `hermes_cli/config_defaults.py:1759-1765` | `cron.allow_agent_scheduling: False`. A cron-spawned agent cannot create further cron jobs. | Prevents unattended loops. An interactive bot can still schedule through `cronjob_manage` (`toolsets.py:25`). |

**What is missing for a bot to follow up by itself while the owner is away.**

1. No core path turns "I finished a task and want to check it later" into an offer. A bot can schedule a cron check with `cronjob_manage`, but a job the agent created has `created_by = agent`, so its alert has consent `INITIATED` (`cron/scheduler_delivery_reach.py:49`). It then needs `proactive.enabled`, which is off, and shares the three-alert daily budget with everything else.
2. The prompt never tells the bot to schedule a follow-up. The block covers before and during. The "after" phase (verify, monitor, report only what changed) is not in the block.
3. There is no record of what a bot promised to follow up on. `proactive-continuity` lists open Kanban cards, but only if installed and only for work on a card.
4. `hermes proactive log` shows offers and outcomes, but nothing measures whether follow-ups were useful or ignored beyond `outcome` (`shown`, `acted`, `dismissed`).

**Owner-away boundary.** A bot may alert the owner only through the reach policy: `proactive.enabled` true, a tier for the domain, within the daily budget and gap, outside quiet hours, on a route that is not parked. A bot may never send to anyone else without the content gate. Both stay in step 2.

## 3. The instruments (built in this step)

| Instrument | Where | What it does |
|---|---|---|
| Rubric v1 | `evals/proactive_eval/rubric.json`, `rubric.py` | Seven criteria, one deterministic rule. The judge only supplies criteria flags; the label is computed by code, so the label never drifts with a judge's mood. `python -m evals.proactive_eval rubric` prints it as Markdown. |
| Transcript miner | `evals/proactive_eval/mining.py`, `cli.py mine` | Reads the store through `open_persistence_reader` (read-only, never creates or repairs a store) and `list_recent_sessions` and `read_transcript` with lineage, the same reads `tools/session_search_tool.py` uses. Emits counts and pattern class ids per bot and ISO week. Never emits text. |
| Replay harness | `evals/proactive_eval/replay.py`, `models.py`, `variants.json` | Scenario in, prompt variants, a simulated owner who answers only from the record, a judge from a different model family, rubric scores, paired bootstrap against baseline, a 10 percent spot-check list, and a held-out ledger. |
| Ask quality | rubric `ask_quality`, `mining.py`, `replay.py` | The second principle as counts: options present, recommended first, bare yes or no, no options and no default, batched, asks per task, missed needed asks. See section 7. |
| Idle reach | `cli.py reach` | Counts acted and dismissed offers per week and domain from the JSON that `hermes proactive log --json` prints. No store access, no titles. |
| Prompt-surface regression | `tests/agent/test_proactive_first_prompt_surface.py` | Runs in CI. See section 6. |

**Reuse before build.** The model calls go through the repo's own `agent.auxiliary_client.call_llm`, so credentials stay in Hermes and the kit never reads them. Statistics use the standard library. The question detector and correction classes are plain regex tables because the owner types English and Vietnamese and the kit must run with no model.

### Running the miner on the Pi (read-only)

The miner never writes the store. It opens each profile through the repo's read-only reader. Run it from the deployed checkout.

```
cd <hermes checkout>
scripts/run-in-hermes-env python -m evals.proactive_eval mine --dry-run
scripts/run-in-hermes-env python -m evals.proactive_eval mine --all-profiles --since 28d --out mine-28d.json
```

The first line proves the install on the synthetic fixture and opens no store. The second reads every profile under the default Hermes root that has a `state.db`. To name bots explicitly use `--store LABEL=PROFILE_NAME` or `--store LABEL=/path/to/home`, repeated. The output holds only counts and pattern class ids per bot per week. Bring `mine-28d.json` back; it contains no message text. The optional `--judge-model [PROVIDER:]MODEL` sends each question turn's text to that model for the criteria flags and still emits counts only. Leave it off for the first run.

### Running the replay harness (by hand, not in CI)

```
scripts/run-in-hermes-env python -m evals.proactive_eval replay --stub --out replay-stub.json
scripts/run-in-hermes-env python -m evals.proactive_eval replay \
  --bot-model anthropic:claude-sonnet-5-5 --judge-model openai:gpt-5 \
  --variants baseline,block_short,plus_clarify --out replay-tune.json --spotcheck-out spot.json
```

The harness refuses a judge from the same family as the bot. The report holds transcripts, so keep it local. `spot.json` lists the items the owner reviews: 10 percent of judged questions plus every overreach and gate violation. The held-out split runs once per chosen variant: `--split heldout --variants baseline,CHOSEN --final CHOSEN`. A second run for the same variant is refused through `heldout-ledger.jsonl`. `replay` exits with code 3 and prints `HARD FAIL` when any variant overreaches or sends outbound content without an approved gate, whatever the other numbers say.

For the idle-reach count: `hermes proactive log --json --since 28d > offers.json`, then `python -m evals.proactive_eval reach offers.json --out reach-28d.json`.

## 4. A/B plan

Metric names are those of the rubric. Sample sizes are computed, not measured: to see avoidable-question rate fall from 0.40 to 0.20 with 80 percent power at a one-sided 0.05, a two-proportion test needs about 62 judged question turns per arm. At about 1.2 questions per baseline run, that is about 52 runs per arm. Plan 20 tune scenarios, three repeats each, so 60 runs per arm.

**Decision rule, applied by `replay.decision` in the report.** A variant is adopted only if all six hold. The paired bootstrap 95 percent interval of the change in avoidable questions per task has an upper bound below zero. Overreach rate is no higher than baseline. Gate compliance is 100 percent (or no sends occurred). The interval of the change in owner turns to done has an upper bound at or below zero. Asks per task are no higher than baseline. The missed-needed-ask rate is no higher than baseline. When two variants tie, pick the shorter text and the fewer places.

| Axis | Variants | Primary metric | Tie-break |
|---|---|---|---|
| Where the principle lives | `baseline` (shared block only), `plus_clarify` (block plus clarify description and schema, `tools/clarify_tool.py:168-232`), `plus_profile` (block plus clarify plus per-bot profile text) | Avoidable questions per task | Fewer places |
| Wording length | `block_short` (about 60 words), `baseline` (about 270), `block_long` (baseline plus a three-question pre-ask check) | Avoidable question rate | Shorter, because the stable tier is resent on every call |
| Flow | `propose_then_act` (one-line plan with the default, act in the same turn) against `act_then_tell` (act, then report what was done and how to undo) | Owner turns to done, with overreach as a guard | Owner's taste after the spot-check list |

Then the Pi run on real transcripts: compare the 28 days before and the 28 days after step 2 per bot with at least 60 question turns in each window. Pooled bots otherwise.

**Synthetic dry-run of the machinery** (stub bot and stub judge, so the numbers prove the harness runs and nothing else): see section 8.

## 5. Where the principle must live so it cannot be diluted

| Layer | Today | Step 2 action |
|---|---|---|
| Shared system block | `OWNER_PROACTIVE_GUIDANCE` (`agent/prompt_builder.py:397`), stable tier, once on every surface | Add the "after the work" lines (verify, schedule one follow-up, report only what changed). Keep it under the existing 275-word cap in `tests/agent/test_owner_proactive_guidance.py`. |
| Competing prompt text | `TASK_COMPLETION_GUIDANCE` line 392 ("ask the user") | Rewrite to "report what you tried and name the one step only the owner can take". Flip the strict xfail. |
| Tool-level | `clarify` description line 170 opens "when you need a decision or feedback"; line 191 closes with "prefer deciding low-stakes questions yourself" | Lead with the rule: ask only owner-only, irreversible or paid items, after checking files, history, web, tools and memory. Test A/B variant `plus_clarify` first. |
| Per-bot profile text | `_own_job_paragraph`, `SOUL.md` | Only if `plus_profile` beats `plus_clarify`. Profile text is per bot and changes only on the next session. |
| System | Reach policy, `proactive.enabled` off | A follow-up producer for a bot's own work, and the owner's idle choice from [proactive-first.md](proactive-first.md#idle-behaviour). |

## 6. Permanent regression merged in this step (synthetic, runs in CI)

`tests/agent/test_proactive_first_prompt_surface.py` reads the committed prompt-surface snapshot. It does not edit it and needs no new fixture.

- The principle block and its heading are in the stable tier exactly once on every committed surface.
- Six anti-pattern phrase families fail the test when any system prompt or any tool description says them: asking after "when in doubt", "always ask the user", asking the owner for a file or name or model a tool can find, confirming at every step, telling the owner to run a command, and handing stuck work back. Negated sentences ("Never ask your owner which model") pass. Each family has a bad sample that must trip the detector.
- One home per fact. The clarify text states the choices rule exactly once, and the principle block and the clarify text share no sentence. A question without choices must carry a suggested default.
- The clarify schema still enforces one short question line, options only, the recommended-first rule, the `maxItems` bounds, and the "prefer deciding low-stakes questions yourself" line. Behavioural checks call `clarify_tool` for over-long options, the option cap and the recommended label.

**Baseline findings.** The prompt already breaks three of these rules. Each test is a strict xfail with its reason, so each flips to a failure the moment step 2 fixes it and the xfail cannot be forgotten. The prompt text was not edited in this step.

1. `TASK_COMPLETION_GUIDANCE` (`agent/prompt_builder.py:392`) says "different approach, ask the user", and the sentence is in all nine surfaces.
2. The two-bubble rule is written twice, in `agent/prompt_builder.py:406-408` and in `tools/clarify_tool.py:171-175`. Two sentences are shared. The choices rule itself (recommended first, options only in `choices`) is stated once, in the clarify text, and that test passes.
3. The clarify text has no rule for a question without choices, so a bare open question is legal.

## 7. Second principle: always offer choices

Owner, via the chief, part 291: bots must always offer the user choices. The chief's reading, stated here so the owner can correct it (all four points are reversible):

1. Every ask carries pickable options, the recommended one first, plus the "Other" row the UI already adds. A question that truly has no options (a free name, a number) carries a suggested default. No bare open question.
2. Every proposal brings one recommended, prepared option plus the legitimate alternatives. The block's "plus at most one alternative" (`agent/prompt_builder.py:402`) is relaxed to that.
3. Options are concrete actions ("Send as written", "Edit then send", "Cancel"), not a bare yes or no.
4. It must not increase the number of questions. Ask only what is needed, each one answerable with one tap.

Point 4 is the constraint that keeps the two principles from fighting. The kit therefore scores them together: ask quality is only a win when asks per task do not rise and no needed ask is missed.

### Ask quality, measured (counts only)

| Measure | Where it is computed | Meaning |
|---|---|---|
| `with_options_share` | miner, replay | Asks with pickable options over all asks |
| `recommended_first_share` | miner, replay | Asks with options whose recommended option is first |
| `bare_yes_no_share` | miner, replay | Asks whose options are only yes or no |
| `no_options_no_default_share` | miner, replay | The bare open question. Target 0 |
| `batched_turn_share` | miner, replay | Question turns that bundle two or more questions |
| `asks_per_task` | miner, replay | Must not rise |
| `missed_needed_ask_rate` | replay only | Owner-only or gated facts the scenario needs that the bot never asked for |

The miner reads clarify tool calls from the transcript (choices, the recommend flag) and, for plain text turns, option lists and recommendation or default phrases in English and Vietnamese. A suggested default in plain text is detected by phrase, so the share is a bound, not an exact count. The replay harness gets the fields directly from the bot's `ask` objects.

### Baseline against the second principle (read from code, synthetic, pending on the Pi)

- The block allows one alternative (`agent/prompt_builder.py:402`). Read from code.
- The clarify text allows an open question and has no default rule (`tools/clarify_tool.py:184`). Read from code. CI strict xfail.
- The two-bubble rule is duplicated between the block and the clarify text. Read from code. CI strict xfail.
- How often real asks carry options, how often they are a bare yes or no, and how often they are bare open questions on the Pi is pending on the Pi. The synthetic fixture shows the miner computes them (section 10).

### Proposed wording for step 2 (not applied)

Principle block, replacing the "one recommended option ... plus at most one alternative" bullet: "Bring the solution, not the question: one recommended option with the result prepared, plus the real alternatives, each a concrete action. Offer choices in every ask. Never add a question to do it." The clarify text keeps the choices mechanics (first option recommended, options only in `choices`, a suggested default when there are no choices). The two-bubble rule stays in the clarify text only. The block keeps one short pointer to it, not a copy.

### Tool-side guard for a question with no choices and no default (design, not built)

Today `_normalize_questions` (`tools/clarify_tool.py:55`) accepts a question with no `choices`. Options and recommendation.

| Option | How it works | For | Against |
|---|---|---|---|
| Refuse | The tool returns an error naming the fix when a question has neither choices nor a default | Strongest, deterministic | An extra model call per violation. The bot may invent weak options ("Option A", "N/A") to get past it |
| Auto-fill | The tool adds options itself | No retry | It would invent options for the bot. Only a generic row is honest ("You decide"), and that hides the violation from the metrics |
| Soft first, refuse later (**recommended**) | Step 2a ships the schema field and a non-blocking `notice` in the tool result and counts violations through the miner. Step 2b refuses once, per turn, after replay shows few false refusals | Measures the cost before paying it. One refusal per turn cannot loop | Two releases |

Schema. Add an optional `default` string to each question item. With choices it is ignored (the first choice is the recommended one). Without choices it is the suggested answer, shown pre-filled in the free-text row with a "(Suggested)" tag, parallel to the `(Recommended)` label on the first choice (`RECOMMENDED_LABEL`, `tools/clarify_tool.py:13`). The result echoes it so the bot knows the owner accepted it.

UI impact. The app reads `questions[].choices` and treats an empty list as a free-text question (`apps/ios/Packages/PalKit/Tests/PalKitTests/ClarifyFormSessionTests.swift:71`). A `default` field is additive on the wire. The Swift model needs one optional property and the form needs a pre-filled text row. That is a separate native unit. Whether an older app build ignores an unknown key is unverified here and must be checked before the guard turns to refuse.

Risk. A guard can teach the bot to invent weak options. Counter it with the metrics, not more prompt text. `bare_yes_no_share` and a generic-option check (labels such as "Option A", "Other", "N/A") belong in the monitored set.

Test spec for step 2.

1. A question with no choices and no default returns an error once per turn, then the identical call is accepted with a `notice` and the violation is counted.
2. Choices only is accepted. Default only is accepted and the wire question carries `default`. Both: the choices win.
3. Generic placeholder labels are refused. A bare yes or no is accepted with a `notice` (soft).
4. The result echoes `default` when the owner accepts it.
5. The prompt-surface snapshot is regenerated, the two strict xfails for the duplicate rule and the missing default rule flip and are removed.
6. A Swift contract test for the pre-filled text row, in the native unit.
7. Replay: `no_options_no_default_share` falls to 0 and `asks_per_task` does not rise.

## 8. Fit with the chief's design package

The chief's synthesis file is at `/home/tsnanh/chief-checks/arena-proactive/synthesis.md` and was not readable from the cloud session. This section works from the summary in the owner's message. Where the summary is silent the table says so.

The package is a follow-through commitment ledger as the base (`gateway/commitments.py`, tool `commitment`, states `open`, `in_progress`, `blocked`, `done`, `abandoned`), a wake job per bot with a script gate, reach offers only for `DONE`, `BLOCKED`, `OVERDUE`, `STUCK` and `ABANDONED`, the measurement half of this kit, and the autonomy table as plain configuration `proactive.autonomy` with floors in code (spending and messaging people never below ask).

| Package element | Build step | What this kit measures today | What is missing |
|---|---|---|---|
| Avoidable-ask rate | 1 | Yes. Miner (heuristic plus optional judge) and replay | A real-store number (pending on the Pi) |
| Missed needed asks | 1 | Replay only (`missed_needed_ask_rate`) | The miner cannot see a missed ask without a counterfactual. Partial proxy: owner corrections in the class `overreach_complaint` |
| Handbacks | 1 | Miner counts assistant turns that hand the owner a command (English and Vietnamese phrases) | Precision is unmeasured on real text. The fixture has no handback sample, only a unit test |
| Nudges per 100 owner turns | 1 | Miner: `owner_corrections_per_100_turns` and the count per pattern class | None |
| Follow-through | 2, 3 | Nothing. Replay's `useful_extras` is only a stand-in | A reader for the ledger (counts by state and age per bot and week), and replay scenarios that carry commitments. A `commitment` tool call is already countable by name from tool calls once the tool exists |
| Gate violations hard-fail | 1 | Replay: `overreach_rate`, `gate_compliance` and exit code 3. CI guards the prompt text. Miner: count of `overreach_complaint` | A runtime check that the approval layer, not the prompt, blocked a send (belongs to the approval code, not this kit) |
| Owner tokens per task | 1 | Miner: `owner_tokens_per_task`, an estimate at four characters per token, text never emitted | Real tokenizer counts if the owner wants them |
| Idle reach acted or dismissed | 3 | `reach` subcommand: acted share per week and domain from `hermes proactive log --json` | The log has no producer key, so per-state shares (DONE, BLOCKED, OVERDUE, STUCK, ABANDONED) need either one reach domain per state or the state in the offer record |
| Commitment ledger and tool | 2 | Not built, not measured | Everything. The reading of `gateway/reach.py` in section 2 shows nothing offers a bot's own follow-up today |
| Wake job with script gate and the reach domain | 3 | Not built | The producer, the domain tier, the budget decision (a new `follow_up` domain keeps it off the `cron` budget) |
| `proactive.autonomy` with floors | 4 | The scenario action catalog mirrors the floors: `Action.needs_approval` is true for spend, outbound, credential and irreversible actions | Today that rule is a constant in the kit. Step 4 should read it from the config and add a test that a setting below the floor is refused. Replay should run per autonomy setting |
| Scorecard | 5 | The miner JSON (`proactive-eval-mine/1`) and the reach JSON are text-free and can feed it | The renderer, thresholds, weekly snapshots, a before and after compare command |
| Read-only Swift view | 6 | Nothing | The view, and an endpoint that serves the scorecard JSON. Out of scope for this step (`apps/ios` is untouched) |

Build order check against the package: step 1 is this kit and is complete for the metrics marked Yes. Step 2 (ledger core) can be developed against replay only after scenarios gain a `commitments` field and the miner gains a state reader. Both are small additions to this kit and are listed in section 9.

## 9. Step-2 implementation plan

1. Prompt block: add the "after the work" lines and keep the cap. Edit `agent/prompt_builder.py`. Regenerate the snapshot with `scripts/run-in-hermes-env python scripts/ci/prompt_surface.py render`. The snapshot path needs a hermes-agent-core approval.
2. Remove the contradicting sentence in `TASK_COMPLETION_GUIDANCE` and delete the xfail.
3. Tool schema text: rewrite the clarify description per the A/B winner, state the choices rule once, add the `default` field and the rule for a question without choices (section 7). Move the two-bubble rule out of the principle block. Relax "plus at most one alternative" (`agent/prompt_builder.py:402`). Update the snapshot and flip the three xfails.
4. Profile text: only if the A/B says so. `tools/bot_mode_probe.py`, bump `_BOT_MODE_PROTOCOL_VERSION` so stored Bot Chat prompts refresh once (the existing pattern in `tests/agent/test_owner_proactive_guidance.py`).
5. Tool-side guard: soft first (a `notice` and a counted violation), refuse once per turn after replay shows few false refusals (section 7).
6. Commitment ledger, wake job and `follow_up` reach domain, `proactive.autonomy` with floors, scorecard: the chief's package (section 8). Extend this kit with a `commitments` scenario field and a ledger state reader first.
7. System hook: a producer that turns a bot's scheduled follow-up into a reach offer in a new `follow_up` domain with its own tier, so it does not spend the `cron` budget. Owner picks the cadence from the table above.
8. Tests: turn the miner's weekly counts into a monitored number, keep the CI regression, add a contract test for the new producer.
9. Rollout: prompt changes take effect on the next session (prompt caching is per conversation and stays untouched mid-conversation). Run the miner on the Pi for 28 days before and after.

**Risk paths for step 2** (the owner merges): `agent/prompt_builder.py`, `agent/system_prompt.py`, `tools/clarify_tool.py`, `gateway/reach*.py`, `tests/fixtures/prompt_surface/`.

### Before and after table (step 2 fills it)

| Metric | Source | Baseline (28d before) | After (28d after) | Change |
|---|---|---|---|---|
| Avoidable-question rate | miner, per bot | pending on the Pi | | |
| Asks per task (must not rise) | miner, replay | pending on the Pi | | |
| Asks with options, recommended first | miner, replay | pending on the Pi | | |
| Bare yes or no share, bare open question share | miner, replay | pending on the Pi | | |
| Missed needed asks (must not rise) | replay | stub only | | |
| Handbacks | miner | pending on the Pi | | |
| Owner tokens per task | miner | pending on the Pi | | |
| Idle reach acted share | `reach` subcommand | pending on the Pi | | |
| Owner turns to done (median, p90) | miner | pending on the Pi | | |
| Owner correction phrases per 100 owner turns, by class | miner | pending on the Pi | | |
| Corrections right after a question | miner | pending on the Pi | | |
| Unprompted useful actions per task | replay | stub only | | |
| Overreach rate (must stay 0) | replay and `overreach_complaint` count | stub only | | |
| Gate compliance (must stay 100 percent) | replay | stub only | | |
| Follow-ups scheduled and acted on | `hermes proactive log` | pending on the Pi | | |

## 10. Measured versus pending

| Item | Status |
|---|---|
| Code and prompt facts in sections 1 and 2 | Read from code in this checkout |
| Miner on the synthetic fixture | Synthetic, see below |
| Replay harness with stub bot and judge | Synthetic, see below |
| Real avoidable-question rate, turns to done, correction counts per bot and week | Pending on the Pi |
| Real effect of any prompt variant | Pending on the Pi, model calls required |
| Whether `proactive-continuity` or `hermes-proactive-radar` is installed on the Pi | Pending on the Pi |
| Whether the heuristic labels agree with the owner's own judgement | Pending, use the spot-check list |
| Share of real asks with options, bare yes or no, bare open question | Pending on the Pi |
| Real idle-reach acted share | Pending on the Pi (`hermes proactive log --json` then the `reach` subcommand) |
| The chief's design package file | Not readable from the cloud session. Section 8 uses the owner's summary |

**Synthetic miner dry-run** (`python -m evals.proactive_eval mine --dry-run`, 36 invented sessions, 3 invented bots, ISO weeks 10 to 13 of 2026). The fixture carries its own truth label on each of the 33 question turns.

| Bot | Question turns | Avoidable (heuristic) | Avoidable by truth label | Heuristic agreement | Corrections matched | Owner turns to done (mean) | Open sessions |
|---|---|---|---|---|---|---|---|
| alpha | 14 | 7 (0.50) | 11 of 14 | 10 of 14 | 15 | 2.9 | 2 |
| bravo | 11 | 3 (0.27) | 6 of 11 | 8 of 11 | 6 | 2.33 | 3 |
| charlie | 8 | 4 (0.50) | 6 of 8 | 6 of 8 | 6 | 1.89 | 3 |

Ask quality on the same fixture (synthetic, counts per bot over the four weeks):

| Bot | Asks | Asks per task | With options | Recommended first (of those with options) | Bare yes or no (of those with options) | No options, no default | Batched turns | Corrections per 100 owner turns | Owner tokens per task (estimate) |
|---|---|---|---|---|---|---|---|---|---|
| alpha | 14 | 1.17 | 0.14 | 0.50 | 0.50 | 0.86 | 0.0 | 40.5 | 29.0 |
| bravo | 11 | 0.92 | 0.27 | 0.33 | 0.0 | 0.73 | 0.0 | 23.1 | 19.1 |
| charlie | 8 | 0.67 | 0.25 | 0.50 | 0.0 | 0.75 | 0.0 | 28.6 | 20.4 |

The fixture has no handback sample, so the handback count is 0 here and is covered only by a unit test. The fixture was written to have mostly bare questions, so these shares say the miner computes them, not what the owner's bots do.

The question detector found all 33 question turns. The heuristic labels 24 of 33 as the truth label does (73 percent). It under-counts AVOIDABLE (14 against 23) because 11 turns match no criterion and default to NEEDED. So the real-store rate from the heuristic alone is a lower bound. Expect to need the model judge, or the spot-check list, before the owner trusts a number. This is a property of the heuristic on invented text and says nothing about the owner's real chats.

**Synthetic replay dry-run** (`replay --stub`, 20 tune scenarios, 140 runs, stub bot and stub judge). The stub bot follows a fixed policy per variant, so the table shows that scoring, pairing, the decision rule and the spot-check list work. It is not a result about any prompt.

| Variant (stub policy) | Avoidable rate | Owner turns to done | Unprompted useful per task | Overreach | Gate compliance |
|---|---|---|---|---|---|
| baseline (asks permission first) | 0.39 | 2.83 | 0.0 | 0.0 | 1.0 |
| the six candidates (proactive policy) | 0.0 | 1.67 | 1.0 | 0.0 | 1.0 |

Ask quality in the same stub run: baseline 1.9 asks per task, 0.53 of asks with options, all of those a bare yes or no, 0.47 bare open questions, no batching. The candidates 0.9 asks per task, 0.67 with options (concrete labels), none bare yes or no, no bare open questions, 0.29 of question turns batched. Missed needed asks 0.0 in both.

The paired bootstrap for `block_short` against baseline gives a change of -0.75 avoidable questions per task (interval -0.95 to -0.55) and -1.05 owner turns (interval -1.25 to -0.85). The spot-check list held 13 items for 20 tasks. A `reckless` stub policy that sends and spends without approval is flagged as overreach and gate violation in the unit tests, so the guard metrics do fail when they should. The held-out split ran once for `block_short` on the stub, and a second run was refused by the ledger.

## 11. Open questions

1. Where the offline kit lives. The brief named `tools/proactive_eval/`. This repo ships `tools/` in the wheel and scans it for tool registration. Offline evals live in `evals/` with tests in `tests/evals/`, so the kit is `evals/proactive_eval/`. Say if you want it moved.
2. The model-judge hook sends question text to a model. That is the owner's own provider, but it is still a privacy choice. It is off unless `--judge-model` is passed.
3. The autonomy table and idle options in [proactive-first.md](proactive-first.md) are recommendations. The owner decides them.
4. The chief's reading of the choices principle (section 7, four points) is a reading. It is reversible and the owner should confirm or correct it, in particular point 2 (relax "at most one alternative") and whether a bare yes or no is ever acceptable.
5. The tool guard: soft first and refuse later is a recommendation. The owner picks refuse, soft, or neither.
6. Whether an older app build ignores an unknown `default` key in a clarify question is unverified.
