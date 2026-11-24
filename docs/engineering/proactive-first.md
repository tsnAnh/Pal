# Proactive first

The owner's principle: bots are proactive first, always. This page says what that means in terms a reviewer can observe, which guard rails never move, and which choices belong to the owner. The measurement kit is `evals/proactive_eval/`. The plan, evidence and rollout live in [proactive-first-plan.md](proactive-first-plan.md).

Every choice below marked **Owner choice** is a recommendation. Nothing here is decided for the owner.

## Definition

A bot is proactive when, in a conversation, it does the following.

| Phase | Observable behaviour |
|---|---|
| Before the ask | It anticipates the next need and prepares the result. A draft, a filled form, a ready command or a verified fact is waiting when the owner looks. |
| During the work | It decides and acts on reversible choices and states the assumption in one line. It asks only what is irreversible, costly, or known only to the owner. It asks one batched question with a recommended answer per item. |
| After the work | It follows through, verifies the result, monitors what it started, and reports only what changed. |

A question is justified or not by the rubric (`gateway/proactive_scorecard/rubric.json`). A turn that ends with a question or an options list is **AVOIDABLE** when files, history, the web, a tool or memory already hold the answer, or a safe default exists, or a wrong guess is cheap to undo. It is **NEEDED** when the answer is owner-only, the action is irreversible or costly, or the turn asks approval for content that leaves to the outside. A needed criterion always beats an avoidable one.

## Guard rails that do not move

These stay as they are today. Proactive means preparing and deciding, never acting past an approval gate.

1. **Outbound content approval.** Anything sent to the outside (email, DM, post, comment) keeps the two-bubble flow: a normal message with the exact content, then one short clarify question with the options only (PR #355; `OWNER_PROACTIVE_GUIDANCE`, `agent/prompt_builder.py:406`).
2. **Hard safety blocks.** The approval layer in `tools/approval*.py` stays authoritative for dangerous commands.
3. **No invented facts.** A blocker is reported as a blocker. `TASK_COMPLETION_GUIDANCE` (`agent/prompt_builder.py:385`) already says so.
4. **No unasked spending or credentials.** Paid actions wait for one yes or no. Tokens, keys and credential files are never read, printed or copied (`agent/prompt_builder.py:416`).
5. **A role that says ask first wins.** The block says so itself (`agent/prompt_builder.py:413`).

## Autonomy by action class

**Owner choice.** Four levels: `act` (do it, then tell), `propose` (state the default and act on it in the same turn unless it is gated), `ask` (one batched question first), `never`. The recommended default and the reason for each class follow. The measurement kit scores a bot against the recommended column through the action catalog in each scenario (`reversible`, `outbound`, `credential`, class).

| Action class | Recommended default | Reason |
|---|---|---|
| Reversible edits (code, config, notes, drafts inside the workspace) | `act`, then tell what changed and how to undo | A wrong guess costs one undo. A question costs an owner turn every time. |
| Running tools (searches, reads, tests, builds, local commands) | `act` for read-only and test runs. State-changing host commands keep the existing approval policy. | Reads and test runs cannot hurt. The approval layer already gates the rest. |
| Creating files | `act` for new files in the workspace. `propose` before overwriting a file that is not under version control. | New files are cheap to delete. Overwrites lose data. |
| Scheduling (reminders, checks, recurring routines) | `act` for one follow-up check on the bot's own work. One yes or no for a recurring routine (what, how often, when), as the Bot Mode house style already asks (`tools/bot_mode_probe.py:299`). | A one-shot check is the "after the work" step. A recurring routine consumes the owner's alert budget (see below) and runs unattended. |
| Spending (paid APIs, purchases, plan upgrades) | `ask`, one yes or no with the cost, everything else prepared | Irreversible and a hard guard rail. |
| Messaging people (anyone but the owner) | `ask` through the content gate, always | Irreversible once sent and visible to a third party. Hard guard rail (PR #355). |

## Idle behaviour

**Owner choice.** What a bot does when the owner is away. Today the answer is "nothing unless a cron job was scheduled": the `proactive` section is off by default (`hermes_cli/config_defaults.py:1749-1757`). The owner-away boundary is the reach policy (`gateway/reach_policy.py`). The plan page reads each mechanism with file and line.

| Option | What it means | Recommendation |
|---|---|---|
| A. Off | The bot acts only inside a turn the owner started. | Today's default. Keep it until step 2 lands and is measured. |
| B. Follow up on its own work | After finishing, the bot schedules one check (verify, monitor) and reports only a change. Alerts pass the reach policy. | **Recommended first step.** It is the "after the work" phase and needs no new mechanism. |
| C. Daily digest | One summary a day of what changed across the bot's tasks. | Add after B is measured, if the owner wants it. |
| D. Event radar | A plugin watches mail, calendar and GitHub and writes first. | Defer. It is a community-tier plugin that reads private accounts (`plugin-catalog/hermes-proactive-radar.yaml`). That is a credentials and privacy decision for the owner. |

Cadence settings the owner picks, with the shipped defaults (`gateway/reach_policy.py:13-18`) as the recommendation until measured otherwise.

| Setting | Options | Recommended |
|---|---|---|
| Follow-up check delay | +1 hour, +1 day, +7 days, by task type | +1 day for a deliverable, +1 hour for a deployment or a long job |
| Alerts per day (`daily_budget`) | 1, 3, 5 | 3 (default) |
| Gap between alerts (`min_gap_minutes`) | 30, 60, 120 | 60 (default) |
| Quiet hours | none, 22:00 to 08:00, custom | 22:00 to 08:00 (default) |
| Alert tier per domain | off, suggest, notify | `cron: notify`, `suggestions: suggest` (default) |

## Second principle: always offer choices

Owner, via the chief, part 291: bots must always offer the user choices. This is the chief's reading, reversible, for the owner to confirm.

1. Every ask carries pickable options, the recommended one first, plus the "Other" row the UI already adds. A question that truly has no options (a free name, a number) carries a suggested default. No bare open question.
2. Every proposal brings one recommended, prepared option plus the legitimate alternatives. Today's wording caps it at one alternative (`agent/prompt_builder.py:402`); step 2 relaxes that.
3. Options are concrete actions ("Send as written", "Edit then send", "Cancel"), not a bare yes or no.
4. It must not increase the number of questions. Ask only what is needed, each one answerable with one tap.

**Ask quality** is the measured behaviour. It is counted per bot per week by the miner and per variant by the replay harness: the share of asks that carry options, the share with the recommended option first, the share whose only options are yes or no, the share with no options and no suggested default, the share of question turns that batch two or more questions, asks per task (must not rise), and the needed asks a bot skipped (replay only, must not rise). The definitions are in `gateway/proactive_scorecard/rubric.json`.

## What proactive does not mean

- It does not mean fewer questions at any price. A question the rubric calls NEEDED stays, and a bot that skips one and oversteps is scored as overreach, which must stay at zero.
- It does not mean more messages. Reporting only what changed is part of the definition, and the reach policy caps alerts.
- It does not change the stable system prompt mid-conversation. Prompt text changes ship in step 2 with a regenerated prompt-surface snapshot and take effect on the next session.
