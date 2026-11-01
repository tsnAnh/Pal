import { host, Switch, useI18n } from '@hermes/plugin-sdk'
import { useState } from 'react'

import { useBots } from './i18n'
import { RoutineRunPanel } from './routine-run-panel'
import { RoutineTriggers } from './routine-triggers'
import { setRoutineActive } from './routines-api'
import type { RosterRow, RoutineJob } from './types'

interface RoutineOperationsProps {
  actions: readonly string[] | undefined
  job: RoutineJob
  locked: boolean
  onChanged: () => Promise<void> | void
  owner: RosterRow
}

function ActiveSwitch({ job, locked, onChanged, owner }: Omit<RoutineOperationsProps, 'actions'>) {
  const b = useBots()
  const { t } = useI18n()
  const [pending, setPending] = useState<boolean | null>(null)
  const serverActive = !locked && job.enabled !== false && job.state !== 'paused'
  const active = pending ?? serverActive

  if (pending !== null && pending === serverActive) {
    setPending(null)
  }

  const toggle = async (next: boolean) => {
    setPending(next)

    try {
      await setRoutineActive(owner, job.job_id, next)
      await onChanged()
    } catch (error) {
      setPending(null)
      host.notifyError(error, t.cron.failedUpdate)
    }
  }

  return (
    <div className="flex items-center justify-between gap-3">
      <div className="grid min-w-0 gap-0.5">
        <span className="text-xs font-medium">{b.routines.active.label}</span>
        <span className="text-[0.65rem] leading-4 text-(--ui-text-quaternary)">{b.routines.active.description}</span>
      </div>
      <Switch
        aria-label={b.routines.active.label}
        checked={active}
        disabled={locked}
        onCheckedChange={value => void toggle(value)}
        size="xs"
      />
    </div>
  )
}

export function RoutineOperations({ actions, job, locked, onChanged, owner }: RoutineOperationsProps) {
  const paused = locked || job.enabled === false || job.state === 'paused'

  return (
    <div className="grid gap-4">
      <ActiveSwitch job={job} locked={locked} onChanged={onChanged} owner={owner} />
      <RoutineRunPanel actions={actions} job={job} owner={owner} paused={paused} />
      <RoutineTriggers actions={actions} job={job} owner={owner} />
    </div>
  )
}
