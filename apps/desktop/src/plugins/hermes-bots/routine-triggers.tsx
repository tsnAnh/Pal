import {
  Button,
  ConfirmDialog,
  CopyButton,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  GlyphSpinner,
  useI18n,
  useQuery,
  useQueryClient
} from '@hermes/plugin-sdk'
import { useState } from 'react'

import { type BotsText, useBots } from './i18n'
import {
  type IssuedTrigger,
  issueTrigger,
  loadTriggerStatus,
  removeTrigger,
  routineOwnerKey,
  supportsRoutineAction,
  TriggerRefusal
} from './routines-api'
import { ID } from './shared'
import type { RosterRow, RoutineJob } from './types'

type Confirming = 'regenerate' | 'remove' | null

interface RoutineTriggersProps {
  actions: readonly string[] | undefined
  job: RoutineJob
  owner: RosterRow
}

function triggerErrorText(error: unknown, c: BotsText['routines']['triggers']): string {
  const reason = error instanceof TriggerRefusal ? error.reason : ''

  switch (reason) {
    case 'conflict':
      return c.conflict

    case 'webhook_disabled':
      return c.blockedWebhook

    case 'gateway_stopped':
      return c.blockedGateway

    default:
      return c.failed
  }
}

function IssuedTriggerCard({ issued, onDone }: { issued: IssuedTrigger; onDone: () => void }) {
  const c = useBots().routines.triggers

  return (
    <div className="grid gap-2 rounded-md border border-(--ui-stroke-secondary) px-3 py-2.5">
      <div className="text-xs font-medium">{c.createdTitle}</div>
      {(
        [
          [c.urlLabel, issued.url, c.copyUrl],
          [c.keyLabel, issued.key, c.copyKey]
        ] as const
      ).map(([label, value, copy]) => (
        <div className="grid gap-0.5" key={label}>
          <span className="text-[0.65rem] text-(--ui-text-tertiary)">{label}</span>
          <div className="flex min-w-0 items-center gap-1">
            <code className="min-w-0 flex-1 select-all break-all font-mono text-[0.7rem] leading-4">{value}</code>
            <CopyButton appearance="icon" buttonSize="icon-xs" label={copy} text={value} />
          </div>
        </div>
      ))}
      <div className="text-[0.65rem] leading-4 text-(--ui-accent)">{c.onceNote}</div>
      <div className="text-[0.65rem] leading-4 text-(--ui-text-tertiary)">{c.howToSend}</div>
      <div className="text-[0.65rem] leading-4 text-(--ui-text-tertiary)">{c.payloadNote}</div>
      <div>
        <Button onClick={onDone} size="sm" variant="secondary">
          {c.done}
        </Button>
      </div>
    </div>
  )
}

export function RoutineTriggers({ actions, job, owner }: RoutineTriggersProps) {
  const c = useBots().routines.triggers
  const { t } = useI18n()
  const queryClient = useQueryClient()
  const supported = supportsRoutineAction(actions, 'trigger_status')
  const [issued, setIssued] = useState<IssuedTrigger | null>(null)
  const [confirming, setConfirming] = useState<Confirming>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<null | string>(null)
  const queryKey = [ID, 'routine-trigger', routineOwnerKey(owner), job.job_id]

  const status = useQuery({
    enabled: supported,
    queryFn: () => loadTriggerStatus(owner, job.job_id),
    queryKey,
    retry: false
  })

  const refresh = () => queryClient.invalidateQueries({ queryKey })

  const issue = async () => {
    const next = await issueTrigger(owner, job.job_id)

    setIssued(next)
    await refresh()
  }

  const create = async () => {
    setBusy(true)
    setError(null)

    try {
      await issue()
    } catch (err) {
      setError(triggerErrorText(err, c))
    } finally {
      setBusy(false)
    }
  }

  const remove = async () => {
    try {
      await removeTrigger(owner, job.job_id)
    } catch (err) {
      throw new Error(triggerErrorText(err, c))
    }

    setIssued(null)
    await refresh()
  }

  const regenerate = async () => {
    try {
      await issue()
    } catch (err) {
      throw new Error(triggerErrorText(err, c))
    }
  }

  const data = status.data
  const blockedText = data?.blocked_by === 'webhook_disabled' ? c.blockedWebhook : c.blockedGateway

  return (
    <div className="grid gap-2">
      <div className="text-xs font-medium text-(--ui-text-secondary)">{c.title}</div>
      {!supported ? (
        <div className="text-xs text-(--ui-text-tertiary)">{c.needsUpdate}</div>
      ) : status.isLoading ? (
        <GlyphSpinner className="text-(--ui-text-tertiary)" spinner="breathe" />
      ) : status.error || !data ? (
        <div className="flex items-center gap-2 text-xs text-(--ui-accent)">
          {c.loadFailed}
          <Button onClick={() => void status.refetch()} size="xs" variant="text">
            {t.common.retry}
          </Button>
        </div>
      ) : (
        <>
          {issued ? <IssuedTriggerCard issued={issued} onDone={() => setIssued(null)} /> : null}
          {data.configured && !issued ? (
            <div className="grid gap-1.5">
              <div className="flex min-w-0 items-center gap-2 text-xs">
                <span className="shrink-0 font-medium">{c.webhook}</span>
                <span className="min-w-0 flex-1 truncate text-(--ui-text-tertiary)">{data.url}</span>
                {data.url ? <CopyButton appearance="icon" buttonSize="icon-xs" label={c.copyUrl} text={data.url} /> : null}
              </div>
              <div className="flex items-center gap-3">
                <Button onClick={() => setConfirming('regenerate')} size="xs" variant="text">
                  {c.regenerate}
                </Button>
                <Button onClick={() => setConfirming('remove')} size="xs" variant="text">
                  {c.remove}
                </Button>
              </div>
            </div>
          ) : null}
          {!data.configured ? (
            <div className="grid gap-1.5">
              <div>
                <DropdownMenu>
                  <DropdownMenuTrigger asChild>
                    <Button disabled={!data.available || busy} size="sm" variant="secondary">
                      {busy ? <GlyphSpinner spinner="breathe" /> : null}
                      {c.add}
                    </Button>
                  </DropdownMenuTrigger>
                  <DropdownMenuContent align="start">
                    <DropdownMenuItem onSelect={() => void create()}>{c.webhook}</DropdownMenuItem>
                  </DropdownMenuContent>
                </DropdownMenu>
              </div>
              <div className="text-[0.65rem] leading-4 text-(--ui-text-quaternary)">
                {data.available ? c.webhookSummary : blockedText}
              </div>
            </div>
          ) : null}
          {error ? (
            <div className="text-xs text-(--ui-accent)" role="alert">
              {error}
            </div>
          ) : null}
        </>
      )}
      <ConfirmDialog
        busyLabel={c.regenerating}
        confirmLabel={c.regenerateConfirm}
        description={c.regenerateBody}
        dismissOnConfirm
        onClose={() => setConfirming(null)}
        onConfirm={regenerate}
        open={confirming === 'regenerate'}
        title={c.regenerateTitle}
      />
      <ConfirmDialog
        busyLabel={c.removing}
        confirmLabel={c.removeConfirm}
        description={c.removeBody}
        destructive
        dismissOnConfirm
        onClose={() => setConfirming(null)}
        onConfirm={remove}
        open={confirming === 'remove'}
        title={c.removeTitle}
      />
    </div>
  )
}
