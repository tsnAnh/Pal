import { relativeTime } from '@hermes/plugin-sdk'
import { type ReactNode, useEffect, useState } from 'react'

import { useBots } from './i18n'
import { previewSchedule, type SchedulePreview, scheduleReasonText, scheduleTooFrequent } from './routines-api'
import type { RosterRow } from './types'

const PREVIEW_DEBOUNCE_MS = 350

interface SchedulePreviewOptions {
  describe: (schedule: string) => string
  owner: RosterRow
  remote: boolean
  schedule: string
}

interface Settled {
  result: 'unavailable' | SchedulePreview
  schedule: string
}

export interface SchedulePreviewState {
  blocked: boolean
  notice: ReactNode
}

function Notice({ children, problem }: { children: ReactNode; problem?: boolean }) {
  return (
    <div
      className={problem ? 'text-[0.65rem] text-(--ui-accent)' : 'text-[0.65rem] text-(--ui-text-tertiary)'}
      role={problem ? 'alert' : 'status'}
    >
      {children}
    </div>
  )
}

/** What the user typed, normalized by the gateway and shown back; a cadence under the minimum is
 *  refused before anything is sent. `remote` gates the gateway call for gateways that cannot preview. */
export function useSchedulePreview({
  describe,
  owner,
  remote,
  schedule
}: SchedulePreviewOptions): SchedulePreviewState {
  const c = useBots().routines.schedule
  const typed = schedule.trim()
  const tooFrequent = scheduleTooFrequent(typed)
  const [settled, setSettled] = useState<null | Settled>(null)

  useEffect(() => {
    if (!remote || !typed || tooFrequent) {
      return
    }

    let current = true

    const timer = setTimeout(() => {
      previewSchedule(owner, typed)
        .then(result => current && setSettled({ result, schedule: typed }))
        .catch(() => current && setSettled({ result: 'unavailable', schedule: typed }))
    }, PREVIEW_DEBOUNCE_MS)

    return () => {
      current = false
      clearTimeout(timer)
    }
  }, [owner, remote, tooFrequent, typed])

  if (tooFrequent) {
    return { blocked: true, notice: <Notice problem>{c.tooFrequent}</Notice> }
  }

  const result = settled?.schedule === typed ? settled.result : null

  if (!remote || !typed || result === 'unavailable') {
    return { blocked: false, notice: null }
  }

  if (!result) {
    return { blocked: false, notice: <Notice>{c.checking}</Notice> }
  }

  if (!result.success) {
    return { blocked: true, notice: <Notice problem>{scheduleReasonText(result.reason, c)}</Notice> }
  }

  const next = result.next_run_at ? new Date(result.next_run_at).getTime() : Number.NaN

  return {
    blocked: false,
    notice: (
      <Notice>
        {c.runs(describe(result.schedule))}
        {Number.isFinite(next) ? ` · ${c.nextRun(relativeTime(next))}` : ''}
      </Notice>
    )
  }
}
