---
name: verify-cron-occurrences
description: "Model-check the cron scheduler's restart-safe dispatch (tick advance, pending_slot stamp, fire claim, crash restore) with TLA+ and TLC. Use when a change touches cron/jobs.py, cron/occurrences.py, cron/missed_runs.py, cron/scheduler_tick.py, cron/scheduler_gateway_gate.py, or the dispatch and claim code in cron/scheduler.py, or before you claim that a recurring job fires exactly once."
---

# Verify cron occurrences

This skill checks one promise of `cron/AGENTS.md`. Every occurrence of a recurring job is accounted for, across ticks, crashes, restarts, and a second ticker on the same store. The check is a TLA+ model that TLC explores exhaustively within fixed bounds. A pass covers the model and its bounds, not the whole scheduler.

## What it verifies

- `AtMostOnce`. One scheduled occurrence of a recurring job never starts two runs. If it breaks, a user gets a duplicate delivery and duplicate side effects.
- `NoSilentLoss`. An occurrence that a tick took off the schedule stays recorded in the job's `pending_slot` until a run claims it or a logged policy skips it. If it breaks, a scheduled run never happens and no log or ledger row says why (#107485).

The scope is built-in recurring (`cron` and `interval`) jobs on the tick path, with two tickers on one store, up to three process deaths, and restarts. `NoSilentLoss` is a job-level promise. A stamp or a live dispatch for any earlier or later slot counts, because a later scan restores it and runs the job once for the whole backlog.

## Run it

```
python .agents/skills/verify-cron-occurrences/scripts/verify.py
```

- It needs Java 11 or newer. The first run downloads TLC `v1.7.4` (`tla2tools.jar`, sha256 pinned in the script) into the user cache. Pass `--tla2tools PATH` or set `TLA2TOOLS_JAR` to supply the jar yourself. The sha256 must match.
- It needs only the Python standard library. Run it with the repo's Python so that the last step can import `cron.jobs`. Without that environment the replay step prints `skipped` and everything else still runs. Add `--require-replay` to make a skipped replay fail.
- It takes about 30 seconds. Exit code 0 means every result matches `coverage.json`, including the findings that are expected to fail. The last line lists them, as in `RESULT PASS (known findings still open: F-A, F-B, F-C, F-D)`. TLC stops at the first violation, so the state count of a violating run changes from run to run. The `envelope` count does not.
- Narrow it with `--code-only`, `--model-only`, `--only cfg1,cfg2`, or `--no-replay`. `--out DIR` keeps the TLC output where you want it.

Read every TLC result with the `/statechart` skill. It turns a violation into its shortest path of steps and draws the state chart when a run passes. Each run's output is `tlc.out` under the output directory that the script prints.

## Read the result

The script prints a `CODE` block, a `MODEL` table, and a `REPLAY` line.

| Kind | Expected | Meaning of a mismatch |
|---|---|---|
| baseline `envelope` | pass | A change broke the protocol under the stated assumptions. Treat it as a bug until proven otherwise. |
| finding | violates | The code still has the hazard. A pass means the hazard was fixed. Update the expectation and the findings below after you confirm the fix. |
| mutant | violates | The check lost its teeth for that broken step. Fix the model, not the mutant. |
| witness | violates | The model no longer reaches that path, so a pass on `envelope` means less. Fix the model. |

Four kinds of line mean the model may no longer describe the code.

- `DRIFT`. A covered definition changed since its recorded fingerprint.
- `FACT`. A call order that the model relies on no longer holds. The line names the mutant that mirrors the break. Facts are pointers. The fingerprint is the guard.
- `MISSING` or `DUPLICATE`. A definition moved, vanished, no longer parses, or is bound twice.
- `REPLAY error`. A step of a finding's replay no longer holds on the real code. The harness error names the step.

To tell a bug from a modeling error, replay the counterexample against the real code, one step per model action. If a step cannot happen, the model is wrong. Fix the model from the code, never from the result. If every step can happen, you found a bug. Report it with the counterexample. Do not weaken a property or a model to make it pass, and do not change product code unless asked.

## Known findings

F-A to F-D reproduce on the real store and gate functions with `scripts/replay_findings.py` (the `REPLAY` line). F-D2 has a replay and no model run. TLC may print the two claims of F-A in the other order. Both orders are reachable.

F-A, a second run of one occurrence. Run by `finding_lease_expiry`.

1. The gateway ticker's tick stamps `pending_slot` for slot S1 in `get_due_jobs`, moves `next_run_at` to S2 in `advance_next_runs`, and registers the dispatch in `_submit_with_guard`. The executor is busy, so the worker has not started.
2. `FIRE_CLAIM_TTL_SECONDS` (300 s) pass. The stamp's lease lapses while its owner is alive.
3. A second ticker (`hermes cron tick` with a ready gateway, or another gateway on the same store) runs `get_due_jobs`. `unclaimed_pending_slot` sees a foreign, expired stamp and returns S1. `_restore_unclaimed_slot` puts `next_run_at` back on S1, and the second ticker dispatches it.
4. The second ticker's worker wins `claim_job_for_fire`, runs S1, and `mark_job_run` clears the claim.
5. The gateway's queued worker starts. `claim_job_for_fire` finds no live claim and wins. S1 runs again.

It needs a queued worker that waits over 300 s, for example in a saturated `cron.max_parallel_jobs` pool. The job's period must also exceed the lease, or the gateway's own next tick restamps with a fresh `at` first. If the restored occurrence is stale and catch-up is off, the second ticker skips it and nothing runs twice.

F-B, a lost occurrence. Run by `finding_stamp_erased`.

1. Run 1 is in flight. Its `claim_job_for_fire` cleared the stamp and set `fire_claim`.
2. Slot S2 comes due before run 1 ends. The next tick's `get_due_jobs` stamps `pending_slot` for S2, and `advance_next_runs` moves `next_run_at` past S2.
3. Run 1 finishes. `mark_job_run` calls `_record_run_outcome`, which runs `job.pop("pending_slot")` and erases the stamp that belongs to S2.
4. The process dies before S2's worker claims. The dispatch exists only in memory.
5. After the restart `next_run_at` is past S2 and no stamp exists. Nothing restores S2. Only `last_dispatch` still names it.

It needs a run that overlaps the next slot. When one process does everything, run 1 must also finish, and release its running-set entry, between the tick's scan and its submit. Otherwise `_submit_with_guard` refuses and logs the skip. With a second ticker there is no such window, because run 1's completion erases that ticker's stamp at any time before its worker claims. The replay reaches the state after step 3. Step 4 is the model's step.

F-C, a stale occurrence lost while the gateway is down. Run by `finding_headless_refusal`.

1. No ready gateway serves the home. It is down, starting, or draining. A system crontab runs `hermes cron tick`, a headless tick. An agent job's occurrence S1 is later than the grace window, which is half a period by default.
2. The scan in `get_due_jobs` finds S1 stale. `fast_forward_missed_recurring` saves `next_run_at` in the future, and the scan stamps `pending_slot` for S1.
3. `refuse_agent_jobs_without_gateway` sees no ready gateway. `_note_fire_refused` runs `job.pop("pending_slot")` and sets `last_fire_error`. It leaves `next_run_at` where the scan put it.
4. S1 is off the schedule and has no stamp. The gate's module text says the job fires at the next tick once the gateway is up. It cannot.

It needs a gateway outage longer than the grace window while a headless tick runs. The replay shows the whole loss, with no model step: a tick inside the window survives the refusal, and the first tick past it loses S1. The loss is also mislabeled. The refusal logs a warning and sets `last_fire_error`, and both say the job runs at the next tick. The scan has already counted a catch-up that never runs (`record_catch_up_occurrence`), and an outage of two slots or more also leaves a `missed` ledger row for it.

F-D, an occurrence dropped with no record. Run by `finding_silent_collapse`.

1. A tick dispatches S1 and queues the worker in `_submit_with_guard`.
2. S2 comes due while the worker waits.
3. The worker's `claim_job_for_fire` sets `next_run_at` to `compute_next_run(now)`, past S2. No stamp covers S2 and no `missed` ledger row books it. Only `fast_forward_missed_recurring` books a gap. `_record_run_outcome` and `_advance_after_run` do the same on completion for slots that came due during a run. That part is read from the code. Neither the model nor the replay exercises it.

The worker must claim before any tick scans S2. Otherwise the scan stamps S2, `_submit_with_guard` logs that the job is already running, and the skip is accounted.

The job still runs once, so the run acts as a catch-up for both slots. The gap is invisible in the run history. The code says "no catch-up queue is needed" in `cron/scheduler_tick.py`, so this is the design. It differs from the words "Never drop a slot silently" in `cron/AGENTS.md`. `envelope` assumes these collapses are accounted (`CollapseIsLogged = TRUE`). The replay shows `next_run_at` past S2 and no `missed` row, and a control shows that a stale scan does book one.

F-D2 is the same loss at the tick for a short-period job. `_compute_grace_seconds` floors grace at 120 s, so a one-minute job scanned 90 s late counts as on time. `fast_forward_missed_recurring` books nothing and `advance_next_runs` jumps past the slot in between. The replay shows `next_run_at` two slots on and an empty ledger. The model does not cover jobs whose grace is a full period or more.

## The check can fail

Each mutant runs under the `envelope` assumptions with one step of the code removed. Each row names the edit to the real code that the mutant mirrors.

| Mutant | Real-code edit | Counterexample |
|---|---|---|
| `mutant_no_stamp` | Drop `pending_slot=pending_slot_stamp(...)` from the `scan.persist(...)` call in `_evaluate_due_job`. | A tick's scan fast-forwards `next_run_at` with no stamp, and the gateway dies. After the restart nothing is due and nothing ran (`NoSilentLoss`). |
| `mutant_claim_keeps_stamp` | Delete `job.pop("pending_slot", None)` in `claim_job_for_fire`. | The gateway stamps slot 1, queues, claims, and dies mid-run. The second ticker restores the leftover stamp, dispatches slot 1, and claims it. Slot 1 runs twice (`AtMostOnce`). |
| `mutant_no_advance` | Remove the `_advance_or_drop_recurring(...)` call from `_tick_admitted`. | The gateway queues slot 1 without advancing. The next tick sees slot 1 due again and queues a second dispatch. Both claim in turn (`AtMostOnce`). |
| `mutant_restore_ignores_lease` | Remove the live-claim early return from `unclaimed_pending_slot`. | The second ticker restores the gateway's live stamp while the gateway's dispatch is queued. The gateway claims and dies, and the second ticker claims the same slot (`AtMostOnce`). |

The three `witness_*` runs must find a violation. They show that a scan restores an orphaned stamp, that the lost-claim branch of `claim_job_for_fire` runs, and that `_submit_with_guard` refuses an already-running job. The `envelope` pass is therefore not vacuous.

## Model to code

Model: `model/CronOccurrences.tla`. Each action carries the name of the code it mirrors.

| Action | One indivisible step in the code |
|---|---|
| `AcquireTickLock` | `scheduler_tick._acquire_tick_lock_or_degrade` |
| `GetDueJobs` | `jobs.get_due_jobs` under `_jobs_lock`. It runs `_evaluate_due_job`, which restores through `_restore_unclaimed_slot`, fast-forwards through `fast_forward_missed_recurring`, then stamps, all in one `save_jobs`. |
| `RefuseHeadless` | `scheduler_gateway_gate.refuse_agent_jobs_without_gateway` and `_note_fire_refused`, for the crontab ticker when no ready gateway serves the home |
| `AdvanceNextRuns` | `scheduler_tick._advance_or_drop_recurring` calling `jobs.advance_next_runs` |
| `SubmitWithGuard` | `scheduler._submit_with_guard` with `try_register_running_job` |
| `ClaimJobForFire` | `scheduler._process_due_job` calling `jobs.claim_job_for_fire` |
| `MarkJobRun` | `jobs.mark_job_run` with `_record_run_outcome` and `_advance_after_run` |
| `ExpireStamp` | the 300 s lease in `jobs._claim_is_live` and `constants.FIRE_CLAIM_TTL_SECONDS` |
| `Crash`, `Restart`, `AdvanceTime` | environment, not code. A restart gets a new `_machine_id()`. |

`cron/AGENTS.md` says the advance and the stamp share one save. In the code the scan saves the stamp and `advance_next_runs` saves the advance in a second save. The model follows the code.

Covered files and definitions. `coverage.json` holds the fingerprints and call-order facts for each.

| File | Definitions |
|---|---|
| `cron/scheduler_tick.py` | `_tick_admitted`, `_acquire_tick_lock_or_degrade`, `_advance_or_drop_recurring` |
| `cron/scheduler_gateway_gate.py` | `refuse_agent_jobs_without_gateway`, `_gateway_unavailable`, `_note_fire_refused` |
| `cron/jobs.py` | `get_due_jobs`, `_get_due_jobs_locked`, `_evaluate_due_job`, `_DueScan.persist`, `_DueJob.recompute_next`, `_compute_grace_seconds`, `_restore_unclaimed_slot`, `advance_next_runs`, `claim_job_for_fire`, `heartbeat_fire_claim`, `mark_job_run`, `_record_run_outcome`, `_advance_after_run`, `_claim_is_live`, `_machine_id`, `_job_running_in_this_process`, `_jobs_lock`, `_with_job`, `_under_fire_fence` |
| `cron/occurrences.py` | `unclaimed_pending_slot`, `pending_slot_stamp` |
| `cron/missed_runs.py` | `fast_forward_missed_recurring`, `job_catches_up`, `count_missed_slots`, `_book_missed` |
| `cron/scheduler_ownership.py` | `_claim_owner_is_dead` |
| `cron/scheduler.py` | `_acquire_tick_lock`, `_submit_with_guard`, `try_register_running_job`, `release_running_job`, `is_job_running`, `_process_due_job` |
| `cron/constants.py` | `FIRE_CLAIM_TTL_SECONDS` |

Sync commit: 48058f84b39fc81de234f815c2be9a480196933f

## Bounds and assumptions

- Bounds. Four occurrences, one recurring job, two tickers, at most three crashes, three incarnations per ticker. The `envelope` run explores about 600,000 states.
- `envelope` assumes the stamp lease never lapses while its owner's dispatch is queued (`StampLeaseCanExpire = FALSE`). The code lets it lapse, which is F-A.
- `envelope` assumes a run ends before the next slot comes due (`RunsFinishWithinSlot = TRUE`). The code lets runs overlap, which is F-B.
- `envelope` assumes a headless tick always finds a ready gateway (`CrontabRefusesWithoutGateway = FALSE`), which is F-C. With the flag on, the refusal can happen at any time, because the gate refuses in every state but ready (down, starting, draining).
- `envelope` assumes a claim or a completion that jumps `next_run_at` forward accounts for every occurrence it passes (`CollapseIsLogged = TRUE`). The code does not log that, which is F-D.
- All runs assume a tick's scan, advance, and submit happen at one clock instant (`TickIsInstant = TRUE`). The real gap is milliseconds to a few seconds.
- Grace. The default grace is half a period, clamped to 120 s through 2 h. The model covers jobs whose grace is below one period, which means a period of 4 minutes or more. A scan that sees an occurrence in its own slot may find it stale or fresh, and one a full slot late is stale (`StaleAfter = 1`). For shorter periods, or a larger `grace_minutes`, a fresh scan can be a period or more late and the tick drops the slots in between with no booking. That is F-D2. It is replayed and not modeled.
- A process is dead exactly when it has crashed and not restarted, which is what `_claim_owner_is_dead` proves for an owner on the same host. A claim stays live while its owner process lives. Cross-host owners and an explicit `HERMES_MACHINE_ID` are not modeled.
- The second ticker stands for another gateway on the store, or for `hermes cron tick`. A headless tick refuses agent jobs while no ready gateway exists, so a second ticker that runs a job after the gateway died stands for a `no_agent` job or another gateway.
- `MarkJobRun` clears the store and the running-set entry in one step. The real code releases the entry a few statements later. The model releases the tick lock at `SubmitWithGuard`. A synchronous `hermes cron tick` holds it longer.

## Not covered

- One-shot jobs, and manual or extra fires (`cron/extra_fire.py`).
- The grace arithmetic in `cron/missed_runs.py` beyond "stale or fresh".
- The executions ledger and `completed_occurrence`.
- The 30 s degraded mode of `_jobs_lock`, and unwritable-store paths (`store_health`).
- External providers, `fire_due`, profile multiplexing, the executor, the restart-safe external worker, and delivery.
- Callee semantics that the model assumes, such as `compute_next_run`, `load_jobs`, `save_jobs` and `create_execution`.
- The replay drives the store and gate functions only, not the scheduler or its executor.

## When a change touches covered code

1. Run the script before you change anything, then after. A `CODE` line names what moved.
2. Read the diff from the sync commit above with `git diff <sync commit> -- <file>` for each flagged file. In a shallow clone, fetch the commit first with `git fetch --depth=1 origin <sync commit>`. Decide for each change whether it has no effect on the model, whether a model step is no longer one indivisible step in the code, or whether the promise changed on purpose.
3. If the model must change, edit `model/CronOccurrences.tla` from the code, rerun, and judge the result as in "Read the result". Add a mutant for any new step that protects a property.
4. Move the sync commit only after you confirm that the verification describes the code at the new commit. Then run `python .agents/skills/verify-cron-occurrences/scripts/verify.py --record --sync <commit>`. It rewrites the fingerprints in `coverage.json` and the sync commit line in this file. Never run it to silence a `DRIFT` you did not read.
5. For changes that skipped this skill, use `/maintain-formal-verification-skill`.
