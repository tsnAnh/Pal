import { Badge, Button, cn, GlyphSpinner, relativeTime, useI18n, useQuery, useQueryClient } from '@hermes/plugin-sdk'
import { useEffect, useRef, useState } from 'react'

import { useBots } from './i18n'
import {
  loadRoutineRuns,
  loadRunOutput,
  routineOwnerKey,
  type RoutineRun,
  startRoutineRun,
  supportsRoutineAction
} from './routines-api'
import { ID } from './shared'
import type { RosterRow, RoutineJob } from './types'

const FAST_POLL_MS = 1500
const IDLE_POLL_MS = 15000
const WATCH_LIMIT_MS = 10 * 60 * 1000

type TestPhase = 'done' | 'idle' | 'running' | 'starting'

interface TestOutcome {
  kind: 'cancelled' | 'failed' | 'queued' | 'refused' | 'started' | 'succeeded' | 'unwatched'
  reason?: string
}

interface RoutineRunPanelProps {
  actions: readonly string[] | undefined
  job: RoutineJob
  owner: RosterRow
  paused: boolean
}

const hasRunning = (runs: RoutineRun[] | undefined) => Boolean(runs?.some(run => run.status === 'running'))

function firstNewRun(runs: RoutineRun[] | undefined, known: ReadonlySet<string>): RoutineRun | undefined {
  return runs?.find(run => !known.has(run.run_id))
}

function outcomeOf(run: RoutineRun): TestOutcome {
  if (run.status === 'succeeded') {
    return { kind: 'succeeded' }
  }

  return { kind: run.status === 'cancelled' ? 'cancelled' : 'failed', reason: run.reason ?? undefined }
}

function useRoutineTest(
  owner: RosterRow,
  job: RoutineJob,
  canRead: boolean,
  runs: RoutineRun[] | undefined,
  refresh: () => void
) {
  const [phase, setPhase] = useState<TestPhase>('idle')
  const [outcome, setOutcome] = useState<null | TestOutcome>(null)
  const knownRuns = useRef<ReadonlySet<string>>(new Set())
  const finished = phase === 'running' ? firstNewRun(runs, knownRuns.current) : undefined

  if (finished && finished.status !== 'running') {
    setPhase('done')
    setOutcome(outcomeOf(finished))
  }

  useEffect(() => {
    if (phase !== 'running') {
      return
    }

    const timer = window.setTimeout(() => {
      setPhase('done')
      setOutcome({ kind: 'unwatched' })
    }, WATCH_LIMIT_MS)

    return () => window.clearTimeout(timer)
  }, [phase])

  const start = async () => {
    setPhase('starting')
    setOutcome(null)

    try {
      const baseline = canRead ? await loadRoutineRuns(owner, job.job_id).catch(() => null) : null
      const result = await startRoutineRun(owner, job.job_id)

      if (!result.started) {
        setPhase('done')
        setOutcome({ kind: 'refused', reason: result.reason })

        return
      }

      if (result.mode === 'queued') {
        setPhase('done')
        setOutcome({ kind: 'queued' })
      } else if (baseline) {
        knownRuns.current = new Set(baseline.map(run => run.run_id))
        setPhase('running')
      } else {
        setPhase('done')
        setOutcome({ kind: 'started' })
      }
    } catch {
      setPhase('done')
      setOutcome({ kind: 'refused' })
    }

    refresh()
  }

  return { outcome, phase, start }
}

function formatDuration(seconds: null | number, c: ReturnType<typeof useBots>['routines']['history']): null | string {
  if (seconds === null) {
    return null
  }

  return seconds < 60 ? c.seconds(Math.max(1, Math.round(seconds))) : c.minutes(Math.round(seconds / 60))
}

function refusalText(reason: string | undefined, c: ReturnType<typeof useBots>['routines']['test']): string {
  switch (reason) {
    case 'paused':
      return c.paused

    case 'already_running':
      return c.alreadyRunning

    case 'not_found':
      return c.notFound

    default:
      return c.unavailable
  }
}

function outcomeText(outcome: TestOutcome, c: ReturnType<typeof useBots>['routines']['test']): string {
  switch (outcome.kind) {
    case 'succeeded':
      return c.succeeded

    case 'queued':
      return c.queued

    case 'started':
      return c.started

    case 'unwatched':
      return c.stoppedWaiting

    case 'cancelled':
      return c.cancelled

    case 'failed':
      return c.failedWith(outcome.reason || c.unavailable)

    default:
      return c.refusedWith(refusalText(outcome.reason, c))
  }
}

const STATUS_BADGE = {
  cancelled: 'outline',
  failed: 'destructive',
  running: 'default',
  succeeded: 'muted'
} as const

function RunOutputView({ job, owner, run }: { job: RoutineJob; owner: RosterRow; run: RoutineRun }) {
  const c = useBots().routines.history

  const { data, error, isLoading } = useQuery({
    queryFn: () => loadRunOutput(owner, job.job_id, run.run_id),
    queryKey: [ID, 'routine-output', routineOwnerKey(owner), job.job_id, run.run_id],
    retry: false,
    staleTime: Infinity
  })

  if (isLoading) {
    return <GlyphSpinner className="text-(--ui-text-tertiary)" spinner="breathe" />
  }

  if (error || !data) {
    return <div className="text-xs text-(--ui-accent)">{c.outputFailed}</div>
  }

  return (
    <div className="grid gap-1">
      <pre className="max-h-48 overflow-y-auto whitespace-pre-wrap break-words rounded-md border border-(--ui-stroke-secondary) px-3 py-2 text-xs leading-5 text-(--ui-text-secondary)">
        {data.output}
      </pre>
      {data.truncated ? <div className="text-[0.65rem] text-(--ui-text-quaternary)">{c.truncated}</div> : null}
    </div>
  )
}

interface RunRowProps {
  expanded: boolean
  job: RoutineJob
  onToggle: () => void
  owner: RosterRow
  run: RoutineRun
}

export function RunRow({ expanded, job, onToggle, owner, run }: RunRowProps) {
  const c = useBots().routines.history
  const started = run.started_at ? new Date(run.started_at).getTime() : Number.NaN
  const duration = formatDuration(run.duration_seconds, c)

  return (
    <div className="grid gap-1.5 text-xs">
      <div className="flex min-w-0 items-center gap-2">
        <Badge size="xs" variant={STATUS_BADGE[run.status]}>
          {c[run.status]}
        </Badge>
        <span className="min-w-0 flex-1 truncate text-(--ui-text-tertiary)">
          {Number.isFinite(started) ? relativeTime(started) : ''}
          {duration ? ` · ${duration}` : ''}
        </span>
        {run.has_output ? (
          <Button onClick={onToggle} size="xs" variant="text">
            {expanded ? c.hideOutput : c.viewOutput}
          </Button>
        ) : null}
      </div>
      {run.reason ? <div className="break-words text-(--ui-accent)">{run.reason}</div> : null}
      {expanded ? <RunOutputView job={job} owner={owner} run={run} /> : null}
    </div>
  )
}

export function RoutineRunPanel({ actions, job, owner, paused }: RoutineRunPanelProps) {
  const b = useBots()
  const { t } = useI18n()
  const queryClient = useQueryClient()
  const canRun = supportsRoutineAction(actions, 'run')
  const canRead = supportsRoutineAction(actions, 'history')
  const [openRunId, setOpenRunId] = useState<null | string>(null)
  const fastPoll = useRef(false)
  const queryKey = [ID, 'routine-runs', routineOwnerKey(owner), job.job_id]

  const history = useQuery({
    enabled: canRead,
    queryFn: () => loadRoutineRuns(owner, job.job_id),
    queryKey,
    refetchInterval: query => (fastPoll.current || hasRunning(query.state.data) ? FAST_POLL_MS : IDLE_POLL_MS),
    retry: false
  })

  const refresh = () => void queryClient.invalidateQueries({ queryKey })
  const test = useRoutineTest(owner, job, canRead, history.data, refresh)
  const running = test.phase === 'starting' || test.phase === 'running' || hasRunning(history.data)

  fastPoll.current = test.phase === 'running'

  const runs = history.data ?? []

  return (
    <div className="grid gap-3">
      <div className="grid gap-1.5">
        <div className="flex items-center gap-2">
          <Button
            disabled={!canRun || paused || running}
            onClick={() => void test.start()}
            size="sm"
            variant="secondary"
          >
            {running ? <GlyphSpinner spinner="breathe" /> : null}
            {running ? b.routines.test.running : b.routines.test.action}
          </Button>
        </div>
        <div className="text-[0.65rem] leading-4 text-(--ui-text-quaternary)">
          {canRun ? (paused ? b.routines.test.paused : b.routines.test.note) : b.routines.test.needsUpdate}
        </div>
        {test.outcome ? (
          <div
            className={cn(
              'text-xs leading-5',
              test.outcome.kind === 'succeeded' || test.outcome.kind === 'queued'
                ? 'text-(--ui-text-secondary)'
                : 'text-(--ui-accent)'
            )}
            role="status"
          >
            {outcomeText(test.outcome, b.routines.test)}
          </div>
        ) : null}
      </div>
      <div className="grid gap-2">
        <div className="text-xs font-medium text-(--ui-text-secondary)">{b.routines.history.title}</div>
        {!canRead ? (
          <div className="text-xs text-(--ui-text-tertiary)">{b.routines.history.needsUpdate}</div>
        ) : history.isLoading ? (
          <GlyphSpinner className="text-(--ui-text-tertiary)" spinner="breathe" />
        ) : history.error ? (
          <div className="flex items-center gap-2 text-xs text-(--ui-accent)">
            {b.routines.history.loadFailed}
            <Button onClick={() => void history.refetch()} size="xs" variant="text">
              {t.common.retry}
            </Button>
          </div>
        ) : runs.length === 0 ? (
          <div className="text-xs text-(--ui-text-tertiary)">{b.routines.history.empty}</div>
        ) : (
          <div className="grid gap-2.5">
            {runs.map(run => (
              <RunRow
                expanded={openRunId === run.run_id}
                job={job}
                key={run.run_id}
                onToggle={() => setOpenRunId(openRunId === run.run_id ? null : run.run_id)}
                owner={owner}
                run={run}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
