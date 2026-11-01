import { loadRoutineRuns, type RoutineRun } from './routines-api'
import type { RosterRow, RoutineJob } from './types'

export const RUN_HISTORY_LIMIT = 20
const JOB_MAX_CHARS = 300

export interface BotRunEntry {
  job: RoutineJob
  run: RoutineRun
}

const squash = (value: null | string | undefined) => (value || '').split(/\s+/).filter(Boolean).join(' ')

export function botJob(description: null | string | undefined, title: null | string | undefined): string {
  const name = squash(title)
  let job = squash(description)

  if (name && job.toLowerCase() === name.toLowerCase()) {
    return ''
  }

  if (name && job.toLowerCase().startsWith(`${name} — `.toLowerCase())) {
    job = job.slice(name.length + 3).trim()
  }

  return job.slice(0, JOB_MAX_CHARS)
}

function startedAt(entry: BotRunEntry): number {
  const time = entry.run.started_at ? new Date(entry.run.started_at).getTime() : Number.NaN

  return Number.isFinite(time) ? time : 0
}

export function mergeRunHistory(entries: readonly BotRunEntry[], limit = RUN_HISTORY_LIMIT): BotRunEntry[] {
  return [...entries].sort((a, b) => startedAt(b) - startedAt(a)).slice(0, limit)
}

export async function loadBotRunHistory(owner: RosterRow, jobs: readonly RoutineJob[]): Promise<BotRunEntry[]> {
  const settled = await Promise.allSettled(jobs.map(async job => (await loadRoutineRuns(owner, job.job_id)).map(run => ({ job, run }))))
  const fulfilled = settled.filter((result): result is PromiseFulfilledResult<BotRunEntry[]> => result.status === 'fulfilled')

  if (jobs.length > 0 && fulfilled.length === 0) {
    throw new Error('Run history unavailable')
  }

  return mergeRunHistory(fulfilled.flatMap(result => result.value))
}
