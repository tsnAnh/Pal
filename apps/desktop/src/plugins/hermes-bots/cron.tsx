/**
 * Routines: the Hermes cron jobs scoped to the bot you're chatting with — the
 * list query and its owner resolution, the schedule picker, the create and
 * detail dialogs, and the pane the right tile renders.
 */

import {
  atom,
  Button,
  Checkbox,
  cn,
  Codicon,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  GlyphSpinner,
  host,
  Input,
  LocalizedTabTitle,
  nextRunOverdueMs,
  PanelEmpty,
  queryClient,
  relativeTime,
  RowButton,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Switch,
  Tabs,
  TabsList,
  TabsTrigger,
  Textarea,
  Tip,
  translateNow,
  useI18n,
  useQuery,
  useValue
} from '@hermes/plugin-sdk'
import { useState } from 'react'

import { AvatarPopover } from './avatar-popover'
import { botJob } from './bot-detail-model'
import { BotDetailsSummary, BotHeaderMenu, BotNameEditor, BotRunHistoryPanel } from './bot-detail-panels'
import { useRoutineOpenRequest } from './bot-detail-state'
import { $focusedBotOwner, $selectedBot, focusedRosterOwner } from './bot-state'
import { $botMeta, $lastRoster, botHandle, botRosterKey, botSelectionKey, isActiveRosterBot } from './data'
import { labeled } from './dialog-parts'
import { EditProfileDialog } from './edit-profile-dialog'
import { botsText, type BotsText, useBots } from './i18n'
import { displayName } from './labels'
import { RoutineOperations } from './routine-operations'
import { useSchedulePreview } from './routine-schedule-preview'
import { supportsRoutineAction, throwIfRoutineRefused } from './routines-api'
import { botConnectionRoute, botRosterMeta, requestForBot } from './routing'
import { ScreenHero } from './screen-hero'
import { ID } from './shared'
import type { BotMeta, RosterRow, RoutineJob } from './types'

const ROUTINES_KEY = [ID, 'routines']

/** Last good cron list, same idea as the roster snapshot. */
const $lastJobs = atom<RoutineJob[]>([])

function showsHandle(name: string, meta: BotMeta | null | undefined, bot?: RosterRow | null) {
  const display = displayName(
    {
      name
    },
    meta
  )

  return Boolean(name && display.toLowerCase() !== botHandle(name, bot).toLowerCase())
}

// ── routines (cron) ──────────────────────────────────────────────────────────
//
// Jobs are namespaced "[bot:<name>] <routine>". A job running in the active
// bot profile uses the plain instruction; a different profile keeps the
// hermes -p <bot> chat delegation wrapper so the run reaches that bot's
// history. The tile follows the bot you're chatting with (gateway profile).
const BOT_TAG_RE = /^\[bot:([a-z0-9][a-z0-9_-]*)\]\s*/i
const SAFE_ROUTINE_MARKER = '[bot-mode:routine:v2] '
const LEGACY_DELEGATED_ROUTINE_PREFIX = 'You are running the scheduled routine "'

/** A routine's owner: a roster row, a bare profile name, or nothing resolved yet. */
type RoutineOwner = RosterRow | string | null | undefined

/** `cron.manage {action: 'list'}` reply. `scoped` carries the profile the
 *  gateway scoped the store to; gateways that ignore `profile` omit it. */
interface RoutineListResult {
  /** The routine actions this gateway supports; older gateways omit it. */
  actions?: string[]
  jobs?: RoutineJob[]
  scoped?: string
}

function routineBot(job: RoutineJob | null | undefined): null | string {
  const match = BOT_TAG_RE.exec(job?.name || '')

  return match ? match[1].toLowerCase() : null
}

export function routineTitle(job: RoutineJob | null | undefined, c: BotsText['cron']): string {
  return (job?.name || '').replace(BOT_TAG_RE, '') || c.untitled
}

export function isLegacyDelegatedRoutine(job: RoutineJob | null | undefined): boolean {
  const preview = typeof job?.prompt_preview === 'string' ? job.prompt_preview : job?.prompt

  return Boolean(routineBot(job) && typeof preview === 'string' && preview.startsWith(LEGACY_DELEGATED_ROUTINE_PREFIX))
}

export async function loadRoutines(owner: RoutineOwner): Promise<RoutineListResult> {
  const bot =
    typeof owner === 'string'
      ? {
          name: owner
        }
      : owner

  const profile = String(bot?.name || '').trim()

  // profile scopes cron.manage to that bot's own cron store (core RPC gained an
  // optional `profile` param). Older gateways ignore the unknown param and
  // return the launch-profile store — the [bot:] tag filter in selectRoutineJobs
  // remains the graceful fallback there.
  const scope = profile
    ? {
        profile
      }
    : {}

  const data = (await requestForBot(bot, 'cron.manage', {
    action: 'list',
    include_disabled: true,
    ...scope
  })) as RoutineListResult

  const jobs = Array.isArray(data?.jobs) ? data.jobs : []

  const activeLegacyJobs = jobs.filter(
    job => isLegacyDelegatedRoutine(job) && job.enabled !== false && job.state !== 'paused'
  )

  // A pause failing must not fail the LIST — the pane would report "could
  // not load cronjobs" over data that loaded fine, and the 20s poll would
  // re-attempt the failing pause inside a failing query forever. Each pause
  // swallows its own error; the overlay only claims jobs the gateway
  // actually paused, and the next poll retries the rest.
  const pauses = await Promise.all(
    activeLegacyJobs.map(job =>
      requestForBot(bot, 'cron.manage', {
        action: 'pause',
        name: job.job_id,
        ...scope
      })
        .then(() => true)
        .catch(() => false)
    )
  )

  if (!activeLegacyJobs.length) {
    return data
  }

  const pausedIds = new Set(activeLegacyJobs.filter((job, index) => pauses[index]).map(job => job.job_id))

  return {
    ...data,
    jobs: jobs.map(job =>
      pausedIds.has(job.job_id)
        ? {
            ...job,
            enabled: false,
            state: 'paused'
          }
        : job
    )
  }
}

function useRoutines(owner: RoutineOwner) {
  const bot =
    typeof owner === 'string'
      ? {
          name: owner
        }
      : owner

  const route = botConnectionRoute(bot)
  const key = route ? botRosterKey(bot) : bot?.name || ''

  return useQuery({
    queryKey: [...ROUTINES_KEY, key],
    queryFn: () => loadRoutines(bot),
    enabled: Boolean(bot?.name),
    refetchInterval: 20000,
    staleTime: 8000
  })
}

/** `activeBot` is always a non-empty profile name, so the result is never
 *  nullish even when no create-owner has been captured yet. */
export function routineCreateTarget(owner: RoutineOwner, activeBot: string): RosterRow | string {
  return owner || activeBot
}

export async function invalidateRoutineOwner(owner: RoutineOwner) {
  const bot =
    typeof owner === 'string'
      ? {
          name: owner
        }
      : owner

  const route = botConnectionRoute(bot)
  const key = route ? botRosterKey(bot) : bot?.name || ''
  await queryClient.invalidateQueries({
    queryKey: [...ROUTINES_KEY, key],
    exact: true
  })
}

/** Pick which cron jobs to show. A failed refresh keeps the last good list. */
export function selectRoutineJobs(
  data: RoutineListResult | undefined,
  error: unknown,
  lastJobs: RoutineJob[],
  bot: string
) {
  const live = Array.isArray(data?.jobs) ? data.jobs : null
  const all = live ?? (error ? lastJobs : [])
  const scopedToBot = normalizedProfileName(data?.scoped) === normalizedProfileName(bot)

  return {
    live,
    all,
    jobs: scopedToBot ? all : all.filter(job => (routineBot(job) || 'default') === bot)
  }
}

/**
 * Why the Routines pane can be empty while the bot's cron store has jobs.
 *
 * On older gateways the pane only shows jobs namespaced `[bot:<name>]` for the
 * active bot (plus untagged legacy jobs on the default bot). When jobs exist in
 * the store but none surface for this bot, the user is left staring at the
 * generic empty state with no hint that cronjobs are present but hidden.
 * Return a short explanation string in that case, or null when the store is
 * genuinely empty (or the active bot's jobs are already shown).
 */
export function routineFilterHint(all: RoutineJob[], jobs: RoutineJob[]): null | string {
  if (jobs.length !== 0 || !Array.isArray(all) || all.length === 0) {
    return null
  }

  return botsText().cron.filterHint
}

export function normalizedProfileName(profile: unknown): string {
  return typeof profile === 'string' ? profile.trim().toLowerCase() : ''
}

function shellQuote(value: unknown): string {
  return `'${String(value).replaceAll("'", "'\"'\"'")}'`
}

export function routineInputError(title: string, instruction: string, c = botsText().cron): null | string {
  if (String(title).includes('\0')) {
    return c.nameNul
  }

  if (String(instruction).includes('\0')) {
    return c.instructionNul
  }

  return null
}

export function routinePrompt(
  bot: string | undefined,
  title: string,
  instruction: string,
  activeProfile: string
): string {
  if (normalizedProfileName(bot) && normalizedProfileName(bot) === normalizedProfileName(activeProfile)) {
    return instruction
  }

  return (
    `${SAFE_ROUTINE_MARKER}You are running the scheduled routine "${title}" for agent '${bot}'. ` +
    `Execute it AS that agent so the run lands in its own history: run this in the terminal and relay the output:\n\n` +
    `hermes -p ${shellQuote(bot)} chat -c ${shellQuote(`Routine: ${title}`)} -q ${shellQuote(`[Scheduled routine] ${instruction}`)}\n\n` +
    `If the command fails, report the error instead.`
  )
}

function cronClockLabel(hour: number, minute: number, locale?: string): string {
  return new Intl.DateTimeFormat(locale, { hour: 'numeric', minute: '2-digit' }).format(
    new Date(2000, 0, 1, hour, minute)
  )
}

function fixedTimeCronLabel(schedule: string, c: BotsText['cron'], locale?: string): null | string {
  const match = /^(\d{1,2}) (\d{1,2}) (\*|\d{1,2}) \* (\*|1-5|[0-6])$/.exec(schedule.trim())

  if (!match) {
    return null
  }

  const [, minute, hour, monthday, weekday] = match

  if (
    Number(minute) > 59 ||
    Number(hour) > 23 ||
    (monthday !== '*' && (Number(monthday) < 1 || Number(monthday) > 31))
  ) {
    return null
  }

  const time = cronClockLabel(Number(hour), Number(minute), locale)

  if (monthday !== '*') {
    return weekday === '*' ? c.runsMonthly(monthday, time) : null
  }

  if (weekday === '*') {
    return c.scheduleAt(c.freqDaily, time)
  }

  if (weekday === '1-5') {
    return c.scheduleAt(c.freqWeekdays, time)
  }

  return c.scheduleAt(translateNow(`cron.days.${weekday}`), time)
}

function scheduleLabel(schedule: string | undefined, locale?: string): string {
  const c = botsText().cron
  const fixed = fixedTimeCronLabel(schedule || '', c, locale)

  if (fixed) {
    return fixed
  }

  const once = /^once in (.+)$/.exec(schedule || '')

  if (once) {
    return c.onceIn(once[1])
  }

  const bare = /^(\d+)([mhd])$/.exec(schedule || '')

  if (bare) {
    return c.onceIn(`${bare[1]}${bare[2]}`)
  }

  const match = /^every (\d+)m$/.exec(schedule || '')

  if (match) {
    const minutes = Number(match[1])

    if (minutes % 1440 === 0) {
      const d = minutes / 1440

      // Daily/Hourly are core's own schedule vocabulary — reuse, don't retranslate.
      return d === 1 ? translateNow('cron.scheduleLabels.daily') : c.everyNDays(d)
    }

    if (minutes % 60 === 0) {
      const h = minutes / 60

      return h === 1 ? translateNow('cron.scheduleLabels.hourly') : c.everyNHours(h)
    }

    return c.everyNMinutes(minutes)
  }

  return schedule || ''
}

/** Absolute + relative rendering of a cron timestamp, or null when the job
 *  has never carried one (a job that has not run yet has no `last_run_at`). */
function routineTimestamp(value: string | undefined): null | string {
  const ms = value ? new Date(value).getTime() : Number.NaN

  return Number.isFinite(ms) ? `${relativeTime(ms)} · ${new Date(ms).toLocaleString()}` : null
}

/** The scheduler's `last_status` literals, spelled out for the inspector. The
 *  set is closed on the gateway side, so every literal is named here — an
 *  unknown one is passed through verbatim rather than hidden. `delivery_failed`
 *  means the agent run succeeded but the brief never reached its target; it
 *  must read as a failure, not as a run result the user can trust. */
export function routineLastResult(status: string | null | undefined, c = botsText().cron): null | string {
  const raw = String(status || '').trim()

  if (!raw) {
    return null
  }

  switch (raw) {
    case 'ok':
      return c.succeeded

    case 'error':
      return c.failed

    case 'delivery_failed':
      return c.deliveryFailed

    case 'blocked_config':
      return c.blockedConfig

    default:
      return raw
  }
}

/** The facts `cron.manage list` already sends with every job, as label/value
 *  rows. Pure so the detail contract is testable without a renderer, and so
 *  the dialog cannot invent a field the gateway never sent: an absent value
 *  drops its row instead of rendering "undefined". */
export function routineDetailRows(
  job: RoutineJob | null | undefined,
  c = botsText().cron
): Array<{ label: string; value: string }> {
  const paused = job?.enabled === false || job?.state === 'paused'
  const label = scheduleLabel(job?.schedule)
  const raw = String(job?.schedule || '').trim()

  // Cells are `number | string | null | undefined` until the filter below
  // drops the non-strings; a destructured, non-predicate callback can't carry
  // that narrowing into the map, so the rows are typed as filtered.
  return (
    [
      [c.status, paused ? c.paused : c.active],
      [c.schedule, label],
      // `scheduleLabel` humanizes "every 1440m" and cron expressions; keep the
      // raw string when it says something the label dropped.
      [c.rawSchedule, raw && raw !== label ? raw : null],
      [c.repeat, job?.repeat],
      // A slot parked past the scheduler grace is labelled overdue, never
      // promised as a next run (#114309); the card below makes the same call.
      [
        job && nextRunOverdueMs(job) !== null ? c.overdueSince : c.nextRun,
        paused ? null : routineTimestamp(job?.next_run_at)
      ],
      [c.lastRun, routineTimestamp(job?.last_run_at)],
      [c.lastResult, routineLastResult(job?.last_status, c)],
      [translateNow('cron.deliverLabel'), job?.deliver],
      [translateNow('cron.modelLabel'), job?.model],
      [c.workdir, job?.workdir]
    ] as Array<[string, string]>
  )
    .filter(([, value]) => typeof value === 'string' && value.trim())
    .map(([name, value]) => ({
      label: name,
      value: value.trim()
    }))
}

/** Why a job is not doing what the user expects. The row only ever showed
 *  "paused"; the scheduler's own reason and the last fire/delivery failures
 *  had no surface in Bot Mode at all. */
export function routineDetailIssue(job: RoutineJob | null | undefined): null | string {
  const reasons = [job?.last_fire_error, job?.last_delivery_error, job?.paused_reason]
  const first = reasons.find(value => typeof value === 'string' && value.trim())

  return first ? first.trim() : null
}

interface RoutineDetailDialogProps {
  actions?: readonly string[]
  job: RoutineJob | null
  onClose: () => void
  open: boolean
  /** Without an owner the inspector stays read-only, as before. */
  owner?: RosterRow
}

/** Inspector for one cronjob, rendered from the list payload the pane already
 *  holds. Given an owner it also hosts the routine's operations: the Active
 *  switch, Test now, run history and triggers. */
export function RoutineDetailDialog({ actions, job, onClose, open, owner }: RoutineDetailDialogProps) {
  const b = useBots()
  const { t } = useI18n()
  const rows = job ? routineDetailRows(job, b.cron) : []
  const issue = job ? routineDetailIssue(job) : null
  const instruction = String(job?.prompt_preview || '').trim()

  return (
    <Dialog
      onOpenChange={value => {
        if (!value) {
          onClose()
        }
      }}
      open={Boolean(open && job)}
    >
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle className="truncate">{routineTitle(job, b.cron)}</DialogTitle>
          <DialogDescription>{b.cron.detailDescription}</DialogDescription>
        </DialogHeader>
        <div className="grid gap-3.5">
          {issue ? (
            <div className="rounded-md border border-(--ui-stroke-secondary) px-3 py-2 text-xs leading-5 text-(--ui-accent)">
              {issue}
            </div>
          ) : null}
          <div className="grid gap-1.5">
            {rows.map(row => (
              <div className="flex items-baseline justify-between gap-3 text-xs" key={row.label}>
                <span className="shrink-0 text-(--ui-text-tertiary)">{row.label}</span>
                <span className="min-w-0 truncate text-right">{row.value}</span>
              </div>
            ))}
          </div>
          {instruction
            ? labeled(
                b.cron.instruction,
                <div className="max-h-48 overflow-y-auto whitespace-pre-wrap break-words rounded-md border border-(--ui-stroke-secondary) px-3 py-2 text-xs leading-5 text-(--ui-text-secondary)">
                  {instruction}
                </div>
              )
            : null}
          {job && owner ? (
            <RoutineOperations
              actions={actions}
              job={job}
              locked={isLegacyDelegatedRoutine(job)}
              onChanged={() => invalidateRoutineOwner(owner)}
              owner={owner}
            />
          ) : null}
        </div>
        <DialogFooter>
          <Button onClick={onClose} variant="secondary">
            {t.common.close}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

interface RoutineRowProps {
  job: RoutineJob
  onOpen?: (job: RoutineJob) => void
  /** The pane only renders rows once it has resolved an exact roster row, so
   *  this never sees the bare-name arm of RoutineOwner. */
  owner: RosterRow
}

export function RoutineRow({ job, onOpen, owner }: RoutineRowProps) {
  const b = useBots()
  const { locale, t } = useI18n()
  const c = t.cron
  const profile = typeof owner === 'string' ? owner : owner?.name
  const [busy, setBusy] = useState(false)
  // Optimistic overlay: null = trust server state. Set immediately on
  // toggle so the switch responds even before the refetch lands.
  const [pendingActive, setPendingActive] = useState<boolean | null>(null)
  const legacyUnsafe = isLegacyDelegatedRoutine(job)
  const serverActive = !legacyUnsafe && job.enabled !== false && job.state !== 'paused'
  const active = pendingActive === null ? serverActive : pendingActive

  if (pendingActive !== null && pendingActive === serverActive) {
    setPendingActive(null) // server caught up
  }

  const act = async (action: 'pause' | 'remove' | 'resume') => {
    if (busy) {
      return
    }

    setBusy(true)

    if (action === 'pause' || action === 'resume') {
      setPendingActive(action === 'resume')
    }

    try {
      await requestForBot(owner, 'cron.manage', {
        action,
        name: job.job_id,
        ...(profile
          ? {
              profile
            }
          : {})
      })
      await invalidateRoutineOwner(owner)
    } catch (err) {
      setPendingActive(null)
      host.notifyError(err, c.failedUpdate)
    } finally {
      setBusy(false)
    }
  }

  const status = !active
    ? c.states.paused
    : job.next_run_at
      ? `${nextRunOverdueMs(job) === null ? c.next : c.overdueSince} ${relativeTime(new Date(job.next_run_at).getTime())}`
      : null

  return (
    <div className="group grid min-w-0 gap-1.5 rounded-xl bg-(--chrome-action-hover) px-3 py-2.5 transition-colors">
      <div className="flex min-w-0 items-center gap-2">
        <RowButton
          className="grid min-w-0 flex-1 gap-0.5 text-left transition-colors hover:text-foreground"
          onClick={() => onOpen?.(job)}
        >
          <span className={cn('min-w-0 truncate text-sm font-medium', !active && 'text-(--ui-text-tertiary)')}>
            {routineTitle(job, b.cron)}
          </span>
          <span className="min-w-0 truncate text-xs text-(--ui-text-tertiary)">
            {scheduleLabel(job.schedule, locale)}
            {status ? <span className="text-(--ui-text-quaternary) first-letter:uppercase"> · {status}</span> : null}
          </span>
        </RowButton>
        <Tip label={t.common.delete}>
          <Button
            aria-label={t.common.delete}
            className="opacity-0 transition-opacity group-hover:opacity-100 focus-visible:opacity-100"
            disabled={busy}
            onClick={() => act('remove')}
            size="icon-xs"
            variant="ghost"
          >
            <Codicon name="trash" />
          </Button>
        </Tip>
        <Switch
          aria-label={b.routines.active.label}
          checked={active}
          disabled={busy || legacyUnsafe}
          onCheckedChange={value => act(value ? 'resume' : 'pause')}
        />
      </div>
      {legacyUnsafe ? (
        <div className="rounded-md border border-(--ui-stroke-secondary) px-2 py-1.5 text-[0.65rem] leading-4 text-(--ui-accent)">
          {b.cron.legacyUnsafe}
        </div>
      ) : null}
    </div>
  )
}

// Structured schedule picker: frequency first, then only the detail that
// frequency needs (time of day, weekday, day of month, interval). Emits a
// Hermes-native schedule string; Advanced exposes it raw.
type ScheduleFreq = 'once' | 'hourly' | 'daily' | 'weekdays' | 'weekly' | 'monthly' | 'interval' | 'advanced'

/** Picker form state. Every detail field stays a string: they are edited as
 *  raw `Input` text and only coerced when the schedule string is composed. */
interface ScheduleState {
  freq: ScheduleFreq
  intervalN: string
  intervalUnit: string
  monthday: string
  onceN: string
  onceUnit: string
  raw: string
  repeatN: string
  time: string
  weekday: string
}

/** Built per call, not frozen at module load: the labels are translated, and
 *  a module const would pin whichever locale happened to be active at import. */
function frequencies(c: BotsText['cron']): Array<{ id: ScheduleFreq; label: string }> {
  return [
    { id: 'once', label: c.freqOnce },
    { id: 'hourly', label: c.freqHourly },
    { id: 'daily', label: c.freqDaily },
    { id: 'weekdays', label: c.freqWeekdays },
    { id: 'weekly', label: c.freqWeekly },
    { id: 'monthly', label: c.freqMonthly },
    { id: 'interval', label: c.freqInterval },
    { id: 'advanced', label: c.freqAdvanced }
  ]
}

/** Weekday names come from core's cron section — it already ships them in
 *  every locale, keyed by the same cron day numbers. */
function weekdays(): Array<{ id: string; label: string }> {
  return ['1', '2', '3', '4', '5', '6', '0'].map(id => ({ id, label: translateNow(`cron.days.${id}`) }))
}

const TIMES = (() => {
  const out = []

  for (let h = 0; h < 24; h++) {
    for (const m of [0, 30]) {
      out.push({
        id: `${h}:${m}`,
        h,
        m
      })
    }
  }

  return out
})()

/** Compose the Hermes schedule string from picker state. */
function composeSchedule(state: ScheduleState): string {
  const [h, m] = (state.time || '9:0').split(':').map(Number)

  switch (state.freq) {
    case 'once': {
      const n = Math.max(1, parseInt(state.onceN, 10) || 1)

      return `in ${n}${state.onceUnit || 'h'}`
    }

    case 'hourly':
      return 'every 1h'

    case 'daily':
      return `${m} ${h} * * *`

    case 'weekdays':
      return `${m} ${h} * * 1-5`

    case 'weekly':
      return `${m} ${h} * * ${state.weekday || '1'}`

    case 'monthly':
      return `${m} ${h} ${state.monthday || '1'} * *`
    case 'interval': {
      const n = Math.max(1, parseInt(state.intervalN, 10) || 1)

      return `every ${n}${state.intervalUnit || 'h'}`
    }

    default:
      return state.raw || ''
  }
}

function scheduleSummary(state: ScheduleState, c: BotsText['cron'], tl: string): string {
  const unitWord = (u: string) => (u === 'm' ? c.unitMinutes : u === 'd' ? c.unitDays : c.unitHours)

  const cap =
    state.freq !== 'once' && String(state.repeatN || '').trim()
      ? c.timesTotal(Math.max(1, parseInt(state.repeatN, 10) || 1))
      : ''

  switch (state.freq) {
    case 'once':
      return c.runsOnce(Math.max(1, parseInt(state.onceN, 10) || 1), unitWord(state.onceUnit))

    case 'hourly':
      return c.runsHourly + cap

    case 'daily':
      return c.runsDaily(tl) + cap

    case 'weekdays':
      return c.runsWeekdays(tl) + cap
    case 'weekly': {
      const days = weekdays()

      return c.runsWeekly((days.find(w => w.id === state.weekday) || days[0]).label, tl) + cap
    }

    case 'monthly':
      return c.runsMonthly(state.monthday || '1', tl) + cap

    case 'interval':
      return c.runsInterval(Math.max(1, parseInt(state.intervalN, 10) || 1), unitWord(state.intervalUnit)) + cap

    default:
      return c.runsRaw
  }
}

function pickerSelect<T extends string>(
  value: T,
  onChange: (value: T) => void,
  options: Array<{ id: T; label: string }>
) {
  return (
    <Select onValueChange={onChange} value={value}>
      <SelectTrigger className="h-8 rounded-md">
        <SelectValue />
      </SelectTrigger>
      <SelectContent>
        {options.map(o => (
          <SelectItem key={o.id} value={o.id}>
            {o.label}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}

interface SchedulePickerProps {
  setState: React.Dispatch<React.SetStateAction<ScheduleState>>
  state: ScheduleState
}

function SchedulePicker({ state, setState }: SchedulePickerProps) {
  const b = useBots()
  const { locale } = useI18n()
  const clock = new Intl.DateTimeFormat(locale, { hour: 'numeric', minute: '2-digit' })
  const times = TIMES.map(time => ({ ...time, label: clock.format(new Date(2000, 0, 1, time.h, time.m)) }))
  const timeLabel = times.find(time => time.id === state.time)?.label ?? clock.format(new Date(2000, 0, 1, 9, 0))

  const upd = (patch: Partial<ScheduleState>) =>
    setState(prev => ({
      ...prev,
      ...patch
    }))

  const needsTime = ['daily', 'weekdays', 'weekly', 'monthly'].includes(state.freq)

  return (
    <div className="grid gap-2">
      <div className={cn('grid gap-2', needsTime ? 'grid-cols-2' : 'grid-cols-1')}>
        {pickerSelect(
          state.freq,
          v =>
            upd({
              freq: v
            }),
          frequencies(b.cron)
        )}
        {needsTime
          ? pickerSelect(
              state.time,
              v =>
                upd({
                  time: v
                }),
              times
            )
          : null}
      </div>
      {state.freq === 'once' ? (
        <div className="grid grid-cols-2 gap-2">
          <Input
            className="h-8"
            onChange={event =>
              upd({
                onceN: event.target.value.replace(/[^0-9]/g, '').slice(0, 4)
              })
            }
            placeholder="30"
            value={state.onceN}
          />
          {pickerSelect(
            state.onceUnit,
            v =>
              upd({
                onceUnit: v
              }),
            [
              {
                id: 'm',
                label: b.cron.minutesFromNow
              },
              {
                id: 'h',
                label: b.cron.hoursFromNow
              },
              {
                id: 'd',
                label: b.cron.daysFromNow
              }
            ]
          )}
        </div>
      ) : null}
      {state.freq === 'weekly'
        ? pickerSelect(
            state.weekday,
            v =>
              upd({
                weekday: v
              }),
            weekdays()
          )
        : null}
      {state.freq === 'monthly'
        ? labeled(
            b.cron.dayOfMonth,
            <Input
              className="h-8"
              onChange={event =>
                upd({
                  monthday: event.target.value.replace(/[^0-9]/g, '').slice(0, 2)
                })
              }
              placeholder="1"
              value={state.monthday}
            />
          )
        : null}
      {state.freq === 'interval' ? (
        <div className="grid grid-cols-2 gap-2">
          <Input
            className="h-8"
            onChange={event =>
              upd({
                intervalN: event.target.value.replace(/[^0-9]/g, '').slice(0, 4)
              })
            }
            placeholder="2"
            value={state.intervalN}
          />
          {pickerSelect(
            state.intervalUnit,
            v =>
              upd({
                intervalUnit: v
              }),
            [
              {
                id: 'm',
                label: b.cron.unitMinutes
              },
              {
                id: 'h',
                label: b.cron.unitHours
              },
              {
                id: 'd',
                label: b.cron.unitDays
              }
            ]
          )}
        </div>
      ) : null}
      {state.freq === 'advanced' ? (
        <Input
          className="h-8 font-mono text-xs"
          onChange={event =>
            upd({
              raw: event.target.value
            })
          }
          placeholder={b.routines.schedule.placeholder}
          value={state.raw}
        />
      ) : null}
      {state.freq !== 'once' && state.freq !== 'advanced' ? (
        <div className="flex items-center gap-2">
          <span className="text-xs text-(--ui-text-tertiary)">{b.cron.stopAfter}</span>
          <Input
            className="h-7 w-16 text-xs"
            onChange={event =>
              upd({
                repeatN: event.target.value.replace(/[^0-9]/g, '').slice(0, 4)
              })
            }
            placeholder="∞"
            value={state.repeatN}
          />
          <span className="text-xs text-(--ui-text-tertiary)">{b.cron.runsHint}</span>
        </div>
      ) : null}
      <div className="text-[0.65rem] text-(--ui-text-quaternary)">{`${scheduleSummary(state, b.cron, timeLabel)} \u00b7 ${composeSchedule(state) || '\u2014'}`}</div>
    </div>
  )
}

function defaultScheduleState(): ScheduleState {
  return {
    freq: 'daily',
    time: '9:0',
    weekday: '1',
    monthday: '1',
    intervalN: '2',
    intervalUnit: 'h',
    onceN: '30',
    onceUnit: 'm',
    repeatN: '',
    raw: ''
  }
}

interface CreateRoutineDialogProps {
  actions?: readonly string[]
  /** Never nullish: the pane early-returns its empty state before it renders
   *  this dialog, so `createTarget` has already fallen back to the active
   *  profile name — which is the bare-name arm, normalized to a row on entry. */
  bot: RosterRow | string
  onClose: () => void
  open: boolean
}

export function CreateRoutineDialog({ actions, bot, open, onClose }: CreateRoutineDialogProps) {
  const b = useBots()
  const { locale, t } = useI18n()
  const c = t.cron
  const [name, setName] = useState('')
  const [instruction, setInstruction] = useState('')
  const [sched, setSched] = useState(defaultScheduleState())
  const [continuity, setContinuity] = useState(false)
  // Where the run's output lands: 'history' = the run session only (Run
  // history / cron page, today's behavior); 'bot-chat' = inject into this
  // bot's canonical Bot Chat as a real message — the bot reads it, acts on
  // it, and responds there (costs the bot one agent turn per run).
  const [target, setTarget] = useState('history')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<null | string>(null)
  const activeProfile = useValue(host.state.profile)
  // Normalize the bare-name arm to a row once, the way loadRoutines /
  // useRoutines / invalidateRoutineOwner already do. Everything below reads
  // `owner.name` — on a raw string those reads are undefined, which silently
  // costs the dialog its title and costs requestForBot its route.
  const owner: RosterRow = typeof bot === 'string' ? { name: bot } : bot
  const profile = owner.name
  const schedule = composeSchedule(sched)

  const schedulePreview = useSchedulePreview({
    describe: value => scheduleLabel(value, locale),
    owner,
    remote: sched.freq === 'advanced' && supportsRoutineAction(actions, 'schedule_preview'),
    schedule
  })

  const reset = () => {
    setName('')
    setInstruction('')
    setSched(defaultScheduleState())
    setContinuity(false)
    setTarget('history')
    setBusy(false)
    setError(null)
  }

  const submit = async () => {
    const title = name.trim()
    const task = instruction.trim()
    const inputError = routineInputError(title, task, b.cron)

    if (inputError) {
      setError(inputError)

      return
    }

    if (!title || !task || !schedule.trim() || busy) {
      return
    }

    setBusy(true)
    setError(null)

    try {
      const repeatN =
        sched.freq !== 'once' && sched.freq !== 'advanced' && String(sched.repeatN || '').trim()
          ? Math.max(1, parseInt(sched.repeatN, 10) || 1)
          : null

      const created = await requestForBot(owner, 'cron.manage', {
        action: 'add',
        name: `[bot:${profile}] ${title}`,
        schedule: schedule.trim(),
        prompt: routinePrompt(profile, title, task, activeProfile),
        ...(profile
          ? {
              profile
            }
          : {}),
        ...(repeatN
          ? {
              repeat: repeatN
            }
          : {}),
        ...(continuity
          ? {
              continuity: true
            }
          : {}),
        // 'bot-chat' (bare, no name): the job is created IN the bot's own
        // cron store (profile scoping above), so the scheduler resolves the
        // token to that profile — no cross-gateway name ambiguity possible.
        ...(target === 'bot-chat'
          ? {
              deliver: 'bot-chat'
            }
          : {})
      })

      throwIfRoutineRefused(created, b.routines.schedule)
      await invalidateRoutineOwner(owner)
      host.notify({
        kind: 'success',
        message: `${c.created}: ${title}`
      })
      reset()
      onClose()
    } catch (err) {
      setBusy(false)
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  const ownerLabel = displayName(owner, botRosterMeta(owner, $botMeta.get()))

  return (
    <Dialog
      onOpenChange={value => {
        if (!value && !busy) {
          reset()
          onClose()
        }
      }}
      open={open}
    >
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>{c.createTitle}</DialogTitle>
          <DialogDescription>{b.cron.createDesc(ownerLabel)}</DialogDescription>
        </DialogHeader>
        <div className="grid gap-3.5">
          {labeled(
            c.nameLabel,
            <Input
              autoFocus
              onChange={event => setName(event.target.value)}
              placeholder={c.namePlaceholder}
              value={name}
            />
          )}
          {labeled(
            c.promptLabel,
            <Textarea
              className="min-h-20"
              onChange={event => setInstruction(event.target.value)}
              placeholder={c.promptPlaceholder}
              value={instruction}
            />
          )}
          {labeled(b.cron.whenToRun, <SchedulePicker setState={setSched} state={sched} />)}
          {schedulePreview.notice}
          {labeled(
            b.cron.sendResultsTo,
            pickerSelect(target, setTarget, [
              {
                id: 'history',
                label: b.cron.runHistoryOnly
              },
              {
                id: 'bot-chat',
                label: b.cron.botChatTarget(ownerLabel)
              }
            ])
          )}
          <label className="flex items-center gap-2 text-xs text-(--ui-text-tertiary) cursor-pointer select-none">
            <Checkbox checked={continuity} onCheckedChange={value => setContinuity(Boolean(value))} />
            {b.cron.continuity}
          </label>
          {error ? (
            <div className="rounded-md border border-(--ui-stroke-secondary) px-3 py-2 text-xs text-(--ui-accent)">
              {error}
            </div>
          ) : null}
        </div>
        <DialogFooter>
          <Button
            disabled={busy}
            onClick={() => {
              reset()
              onClose()
            }}
            variant="ghost"
          >
            {t.common.cancel}
          </Button>
          <Button
            disabled={busy || !name.trim() || !instruction.trim() || !schedule.trim() || schedulePreview.blocked}
            onClick={submit}
          >
            {busy ? t.common.saving : c.createAction}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

interface ProfileSyncOwnerRow {
  connectionId?: string
  profile?: string
}

/** `$focusedBotOwner`: the SDK atom on newer desktops, the synthesized
 *  profile-only fallback on older ones. */
interface ProfileSyncStore {
  get?: () => ProfileSyncOwnerRow | null | string | undefined
  listen: (listener: (owner: ProfileSyncOwnerRow | null | string | undefined) => void) => () => void
}

/** Keeps $selectedBot in sync with the focused chat's owner profile.
 *  nanostores' `.listen()` never replays the current value the way
 *  `.subscribe()` does, so a disable → profile switch → re-enable sequence
 *  would otherwise leave $selectedBot pointed at whichever bot was active
 *  before the plugin was disabled — reseeding here on every register() call
 *  closes that gap. Connection qualification keeps same-named owners isolated.
 *  Returns the unbind function for ctx.onDispose. */
export function bindProfileSync(ownerStore: ProfileSyncStore) {
  const sync = (owner: ProfileSyncOwnerRow | null | string | undefined) => {
    const profile = typeof owner === 'string' ? owner : owner?.profile

    if (!profile || typeof profile !== 'string') {
      return
    }

    const connectionId = String(typeof owner === 'object' ? owner?.connectionId || '' : '').trim()
    $selectedBot.set(connectionId ? `${connectionId}::${profile}` : profile)
  }

  sync(ownerStore.get?.())

  return ownerStore.listen(sync)
}

export function resolveRoutineOwner(
  roster: RosterRow[],
  focusedOwner: { authoritative?: boolean; connectionId?: string; name: string } | null,
  selected: string
): RosterRow | null {
  // A null focused owner is NOT a failure: the SDK fails closed to null
  // whenever the focused session has no unique bot owner (a normal chat,
  // ambiguous owner hints) — the common case while the user browses the
  // Bots pane. Fall through to the roster-clicked bot (the previously
  // working scope) instead of dead-ending the pane on the unavailable
  // placeholder for every agent (#94516).
  const selectedBot = roster.find(bot => botSelectionKey(bot) === selected)
  const focusedBot = focusedOwner ? roster.find(bot => isActiveRosterBot(bot, focusedOwner)) : null

  if (focusedOwner?.authoritative) {
    // An authoritative focused owner wins, but only through its exact roster
    // row. If that row is absent, fail closed instead of routing cron
    // reads/mutations through a stale selection or an unscoped profile name.
    return focusedBot || null
  }

  return (
    focusedBot ||
    selectedBot ||
    (focusedOwner
      ? {
          name: focusedOwner.name
        }
      : null)
  )
}

const PROFILE_TABS = [
  { id: 'details', label: (b: BotsText) => b.cron.profileDetailsTab },
  { id: 'history', label: (b: BotsText) => b.detail.runHistoryTab },
  { id: 'computer', label: (b: BotsText) => b.cron.profileComputerTab }
] as const

export function RoutinesTabTitle() {
  return <LocalizedTabTitle select={t => t.sidebar.filter.profile} />
}

interface BotProfileHeaderProps {
  bot: string
  meta: BotMeta | null
  onAddLabel: () => void
  owner: RosterRow
  profileLabel: string
  profileName: string
}

function BotProfileHeader({ bot, meta, onAddLabel, owner, profileLabel, profileName }: BotProfileHeaderProps) {
  const b = useBots()
  const { t } = useI18n()

  return (
    <div
      className="relative flex flex-col items-center gap-1 px-4 pt-5 pb-3 text-center"
      data-bot-gaze-scope
      data-slot="bot-profile-header"
    >
      {typeof host.closePane === 'function' ? (
        <Button
          aria-label={t.common.close}
          className="absolute top-2 right-2 size-8 rounded-full bg-(--chrome-action-hover) text-(--ui-text-secondary) hover:text-foreground"
          onClick={() => host.closePane(`${ID}:routines`)}
          size="icon"
          variant="ghost"
        >
          <Codicon name="close" />
        </Button>
      ) : null}
      <AvatarPopover bot={bot} meta={meta} owner={owner} />
      <BotHeaderMenu bot={owner} />
      <BotNameEditor bot={owner} name={profileName} />
      {showsHandle(bot, meta, owner) ? (
        <span className="font-mono text-[0.65rem] text-(--ui-text-quaternary)">{`@${botHandle(bot, owner)}`}</span>
      ) : null}
      {profileLabel ? (
        <div className="line-clamp-3 max-w-full text-xs text-(--ui-text-tertiary)">{profileLabel}</div>
      ) : (
        <button
          className="text-xs text-(--ui-text-tertiary) underline-offset-2 hover:text-foreground hover:underline"
          onClick={onAddLabel}
          type="button"
        >
          {b.cron.profileAddLabel}
        </button>
      )}
    </div>
  )
}

function BotProfileTabs({ onChange, tab: profileTab }: { onChange: (tab: string) => void; tab: string }) {
  const b = useBots()
  const { t } = useI18n()

  return (
    <Tabs className="gap-0" onValueChange={onChange} value={profileTab}>
      <TabsList aria-label={t.sidebar.filter.profile} className="mx-auto mb-2 h-auto gap-1 bg-transparent p-0 px-3">
        {PROFILE_TABS.map(tab => (
          <TabsTrigger
            aria-controls={`bot-profile-panel-${tab.id}`}
            className={cn(
              'h-auto rounded-full px-3 py-1 text-xs shadow-none transition-colors',
              profileTab === tab.id
                ? 'bg-(--chrome-action-hover) font-medium text-foreground'
                : 'text-(--ui-text-tertiary) hover:text-foreground'
            )}
            id={`bot-profile-tab-${tab.id}`}
            key={tab.id}
            value={tab.id}
          >
            {tab.label(b)}
          </TabsTrigger>
        ))}
      </TabsList>
    </Tabs>
  )
}

interface BotProfileBodyProps {
  actions: readonly string[] | undefined
  error: unknown
  isLoading: boolean
  jobs: RoutineJob[]
  meta: BotMeta | null
  onCreate: () => void
  onOpenJob: (jobId: string) => void
  owner: RosterRow
  refetch: () => unknown
  tab: string
  view: ReturnType<typeof selectRoutineJobs>
}

function BotProfileBody({
  actions,
  error,
  isLoading,
  jobs,
  meta,
  onCreate,
  onOpenJob,
  owner,
  refetch,
  tab,
  view
}: BotProfileBodyProps) {
  const b = useBots()
  const { t } = useI18n()
  const c = t.cron
  const staleNotice = error && !view.live && view.all.length ? b.cron.staleNotice : null
  const filterHint = routineFilterHint(view.all, jobs)

  return (
    <>
  {tab === 'details' ? (
    <div
      aria-labelledby="bot-profile-tab-details"
      className="flex min-h-0 flex-1 flex-col"
      id="bot-profile-panel-details"
      role="tabpanel"
    >
      <BotDetailsSummary bot={owner} job={botJob(owner.description, meta?.title ?? owner.title)} />
      <div className="flex items-center gap-2 px-4 pt-2 pb-1.5">
        <div className="min-w-0 flex-1 text-sm text-(--ui-text-tertiary)">{b.cron.routinesLabel}</div>
        <Tip label={c.newCron}>
          <Button
            aria-label={c.newCron}
            className="size-6 rounded-full bg-(--chrome-action-hover)"
            onClick={onCreate}
            size="icon-xs"
            variant="ghost"
          >
            <Codicon name="add" />
          </Button>
        </Tip>
      </div>
      {staleNotice ? (
        <div className="mx-3 mb-2 rounded-md bg-(--chrome-action-hover) px-2 py-1.5 text-[0.6875rem] text-(--ui-text-tertiary)">
          {staleNotice}
        </div>
      ) : null}
      {isLoading && !view.all.length ? (
        <div className="flex flex-1 items-center justify-center">
          <GlyphSpinner className="text-(--ui-text-tertiary)" spinner="breathe" />
        </div>
      ) : error && !view.all.length ? (
        <PanelEmpty
          action={
            <Button onClick={() => void refetch()} size="sm" variant="secondary">
              {t.common.retry}
            </Button>
          }
          description={b.cron.readFailure}
          icon="warning"
          title={c.failedLoad}
        />
      ) : jobs.length === 0 ? (
        <div className="px-4 py-2">
          <div className="text-sm text-(--ui-text-tertiary)">{filterHint || c.emptyTitleNew}</div>
        </div>
      ) : (
        <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain">
          <div className="grid gap-2 px-3 py-1">
            {jobs.map(job => (
              <RoutineRow
                job={job}
                key={job.job_id}
                onOpen={opened => onOpenJob(opened.job_id)}
                owner={owner}
              />
            ))}
          </div>
        </div>
      )}
    </div>
  ) : tab === 'history' ? (
    <div
      aria-labelledby="bot-profile-tab-history"
      className="flex min-h-0 flex-1 flex-col"
      id="bot-profile-panel-history"
      role="tabpanel"
    >
      <BotRunHistoryPanel
        actions={actions}
        jobs={jobs}
        owner={owner}
        titleOf={job => routineTitle(job, b.cron)}
      />
    </div>
  ) : (
    <div
      aria-labelledby="bot-profile-tab-computer"
      className="min-h-0 flex-1 overflow-y-auto px-3"
      id="bot-profile-panel-computer"
      role="tabpanel"
    >
      <ScreenHero bot={owner} meta={meta} />
    </div>
  )}
    </>
  )
}

export function RoutinesPane() {
  const selected = useValue($selectedBot)
  const focusedOwner = focusedRosterOwner(useValue($focusedBotOwner))
  // Subscribe instead of a bare read: BotsPane owns the roster fetch and
  // can hydrate (or replace) rows after this pane mounted, so a .get()
  // snapshot captured while the roster was still empty pinned the pane on
  // "unavailable" until some unrelated atom happened to re-render it (#94483).
  // A complete focused owner is still authoritative. If its exact roster row
  // is absent, fail closed rather than routing cron reads/mutations through a
  // stale selection or an unscoped profile name.
  const owner = resolveRoutineOwner(useValue($lastRoster), focusedOwner, selected)
  const bot = String(owner?.name || focusedOwner?.name || 'default').trim() || 'default'
  const allMeta = useValue($botMeta)
  const meta = owner ? botRosterMeta(owner, allMeta) : null
  const { data, error, isLoading, refetch } = useRoutines(owner)
  const b = useBots()
  const { t } = useI18n()
  const c = t.cron
  const [createOpen, setCreateOpen] = useState(false)
  const [editOpen, setEditOpen] = useState(false)
  const [profileTab, setProfileTab] = useState('details')
  const [createOwner, setCreateOwner] = useState<RosterRow | null>(null)
  // Hold the id, not the record: the 20s poll replaces every job object, and
  // an open inspector must follow the live row (next run, pause, last error)
  // instead of freezing the snapshot that was on screen when it opened.
  const [detailJobId, setDetailJobId] = useState<null | string>(null)
  const profileLabel = (meta?.title || owner?.title || owner?.description || meta?.description || '').trim()
  const profileName = (meta?.title || owner?.title || owner?.display_name || bot).trim()
  const createTarget = owner ? routineCreateTarget(createOwner, bot) : null
  const ownerKey = owner ? botRosterKey(owner) : null

  useRoutineOpenRequest(ownerKey, jobId => {
    setProfileTab('details')
    setDetailJobId(jobId)
  })

  const openCreate = () => {
    if (!owner) {
      return
    }

    setCreateOwner(owner)
    setCreateOpen(true)
  }

  if (!owner) {
    return <PanelEmpty description={b.cron.needsRosterFirst} icon="hubot" title={c.title} />
  }

  const view = selectRoutineJobs(data, error, $lastJobs.get(), bot)

  if (view.live) {
    $lastJobs.set(view.live)
  }

  const jobs = view.jobs
  const detailJob = detailJobId ? jobs.find(job => job.job_id === detailJobId) || null : null

  return (
    <div className="flex h-full flex-col">
      <BotProfileHeader
        bot={bot}
        meta={meta}
        onAddLabel={() => setEditOpen(true)}
        owner={owner}
        profileLabel={profileLabel}
        profileName={profileName}
      />
      <BotProfileTabs onChange={setProfileTab} tab={profileTab} />
      <BotProfileBody
        actions={data?.actions}
        error={error}
        isLoading={isLoading}
        jobs={jobs}
        meta={meta}
        onCreate={openCreate}
        onOpenJob={setDetailJobId}
        owner={owner}
        refetch={refetch}
        tab={profileTab}
        view={view}
      />
      <EditProfileDialog bot={editOpen ? owner : null} onClose={() => setEditOpen(false)} open={editOpen} />
      <RoutineDetailDialog
        actions={data?.actions}
        job={detailJob}
        onClose={() => setDetailJobId(null)}
        open={Boolean(detailJob)}
        owner={owner}
      />
      <CreateRoutineDialog
        actions={data?.actions}
        // Non-null past the `!owner` early return above: `routineCreateTarget`
        // falls back to the active profile name.
        bot={createTarget!}
        // TODO(bot-mode-types): `createTarget` is a roster row whenever a create
        // owner is set, so this key stringifies to "[object Object]" instead of
        // identifying the target bot. Cast to keep the as-written behavior.
        key={createTarget as string}
        onClose={() => {
          setCreateOpen(false)
          setCreateOwner(null)
        }}
        open={createOpen}
      />
    </div>
  )
}
