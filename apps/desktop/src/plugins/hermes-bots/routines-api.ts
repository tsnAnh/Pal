import { botRosterKey } from './data'
import type { BotsText } from './i18n'
import { botConnectionRoute, requestForBot } from './routing'
import type { RosterRow } from './types'

export const MIN_INTERVAL_MINUTES = 5

export type RoutineAction =
  'history' | 'history_output' | 'run' | 'schedule_preview' | 'trigger_issue' | 'trigger_remove' | 'trigger_status'

export type RunStatus = 'cancelled' | 'failed' | 'running' | 'succeeded'

export interface RoutineRun {
  duration_seconds: null | number
  finished_at: null | string
  has_output: boolean
  reason: null | string
  run_id: string
  started_at: null | string
  status: RunStatus
}

interface Refusal {
  error?: string
  reason?: string
  success: false
}

export interface RunStart {
  error?: string
  mode?: string
  reason?: string
  started: boolean
}

export interface RunOutput {
  output: string
  truncated: boolean
}

export type SchedulePreview =
  { kind: string; next_run_at: null | string; schedule: string; success: true } | (Refusal & { schedule?: undefined })

export interface TriggerStatus {
  available: boolean
  blocked_by: null | 'gateway_stopped' | 'webhook_disabled'
  configured: boolean
  created_at?: string
  url?: string
}

export interface IssuedTrigger {
  created_at: string
  key: string
  url: string
}

type Owner = Partial<RosterRow>

export function supportsRoutineAction(actions: readonly string[] | undefined, action: RoutineAction): boolean {
  return Array.isArray(actions) && actions.includes(action)
}

export function routineOwnerKey(owner: Owner): string {
  return botConnectionRoute(owner) ? botRosterKey(owner as RosterRow) : String(owner.name || '')
}

function manage<T>(owner: Owner, params: Record<string, unknown>): Promise<T> {
  const profile = String(owner.name || '').trim()

  return requestForBot<T>(owner, 'cron.manage', { ...params, ...(profile ? { profile } : {}) })
}

function refusalOf(result: unknown): null | Refusal {
  const value = result as null | Partial<Refusal>

  return value && value.success === false ? (value as Refusal) : null
}

export async function startRoutineRun(owner: Owner, jobId: string): Promise<RunStart> {
  const result = await manage<RunStart>(owner, { action: 'run', name: jobId })

  return { ...result, started: result.started === true }
}

export async function loadRoutineRuns(owner: Owner, jobId: string): Promise<RoutineRun[]> {
  const result = await manage<{ runs?: RoutineRun[] }>(owner, { action: 'history', name: jobId })

  return Array.isArray(result?.runs) ? result.runs : []
}

export async function loadRunOutput(owner: Owner, jobId: string, runId: string): Promise<RunOutput> {
  const result = await manage<Partial<Refusal & RunOutput>>(owner, {
    action: 'history_output',
    name: jobId,
    run_id: runId
  })

  if (refusalOf(result) || typeof result?.output !== 'string') {
    throw new Error('run_output_unavailable')
  }

  return { output: result.output, truncated: result.truncated === true }
}

export async function previewSchedule(owner: Owner, schedule: string): Promise<SchedulePreview> {
  return manage<SchedulePreview>(owner, { action: 'schedule_preview', schedule })
}

export async function loadTriggerStatus(owner: Owner, jobId: string): Promise<TriggerStatus> {
  const result = await manage<Partial<TriggerStatus & Refusal>>(owner, { action: 'trigger_status', name: jobId })

  if (refusalOf(result)) {
    throw new Error('trigger_status_unavailable')
  }

  return {
    available: result.available === true,
    blocked_by: result.blocked_by ?? null,
    configured: result.configured === true,
    created_at: result.created_at,
    url: result.url
  }
}

export class TriggerRefusal extends Error {
  readonly reason: string

  constructor(reason: string) {
    super(reason)
    this.reason = reason
  }
}

export async function issueTrigger(owner: Owner, jobId: string): Promise<IssuedTrigger> {
  const result = await manage<Partial<IssuedTrigger & Refusal>>(owner, { action: 'trigger_issue', name: jobId })
  const refusal = refusalOf(result)

  if (refusal || typeof result?.key !== 'string' || typeof result?.url !== 'string') {
    throw new TriggerRefusal(refusal?.reason ?? 'unavailable')
  }

  return { created_at: String(result.created_at ?? ''), key: result.key, url: result.url }
}

export async function removeTrigger(owner: Owner, jobId: string): Promise<void> {
  const result = await manage<Refusal>(owner, { action: 'trigger_remove', name: jobId })

  if (refusalOf(result)) {
    throw new Error('trigger_remove_failed')
  }
}

export async function setRoutineActive(owner: Owner, jobId: string, active: boolean): Promise<void> {
  await manage(owner, { action: active ? 'resume' : 'pause', name: jobId })
}

/** The local half of the cadence rule, for gateways that cannot preview and for the picker's structured
 *  intervals: the same "at most once every 5 minutes" the gateway enforces on `add`. */
export function scheduleTooFrequent(schedule: string): boolean {
  const match = /^(?:every\s+)?(\d+)\s*(?:m|min|mins|minute|minutes)$/i.exec(schedule.trim())

  return Boolean(match) && Number(match![1]) < MIN_INTERVAL_MINUTES
}

/** `add` answers a refused schedule as a normal result (`success: false` + a stable `reason`), so the
 *  create dialog needs it turned into the error its catch block already shows. */
export function throwIfRoutineRefused(result: unknown, c: BotsText['routines']['schedule']): void {
  const refusal = refusalOf(result)

  if (!refusal) {
    return
  }

  throw new Error(scheduleReasonText(refusal.reason, c))
}

export function scheduleReasonText(reason: string | undefined, c: BotsText['routines']['schedule']): string {
  switch (reason) {
    case 'too_frequent':
      return c.tooFrequent

    case 'unrecognized':
      return c.unrecognized

    case 'invalid':
      return c.invalid

    default:
      return c.invalid
  }
}
