import { atom, Button, Codicon, host, TOOL_CARD_AREA, useValue } from '@hermes/plugin-sdk'
import type { ToolCardProps } from '@hermes/plugin-sdk'
import { useState } from 'react'

import { undoIdentityChange } from './bot-onboarding'
import { botForChat } from './chat-empty'
import { $lastRoster } from './data'
import { useBots } from './i18n'
import type { RosterRow } from './types'

interface IdentityChange {
  changeId: null | string
  summary: string
  undoAvailable: boolean
}

type NoticeState = 'failed' | 'idle' | 'stale' | 'undoing'

const $undoneChanges = atom<ReadonlySet<string>>(new Set())

const NOTICE_CLASS =
  'mb-1.5 flex w-full flex-wrap items-center justify-start gap-x-2 gap-y-0.5 self-stretch border-b border-(--ui-stroke-secondary) pb-1.5 text-left text-[0.75rem] leading-5 text-(--ui-text-tertiary)'

function parseResult(result: unknown): unknown {
  if (typeof result !== 'string') {
    return result
  }

  try {
    return JSON.parse(result)
  } catch {
    return null
  }
}

export function identityChangeOf(result: unknown): IdentityChange | null {
  const change = (parseResult(result) as { identity_change?: unknown } | null)?.identity_change as
    | { change_id?: unknown; summary?: unknown; undo_available?: unknown }
    | undefined

  if (!change || typeof change.summary !== 'string' || !change.summary.trim()) {
    return null
  }

  return {
    changeId: typeof change.change_id === 'string' && change.change_id ? change.change_id : null,
    summary: change.summary.trim(),
    undoAvailable: change.undo_available === true
  }
}

export const isIdentityCall = (args: Readonly<Record<string, unknown>>): boolean => args?.target === 'identity'

export function IdentityNoticeCard({ args, fallback, result, sessionId }: ToolCardProps) {
  const roster = useValue($lastRoster)
  useValue(host.state.focusedStoredSessionId)
  const bot = botForChat(roster, sessionId ?? '')

  if (!isIdentityCall(args) || !bot) {
    return <>{fallback}</>
  }

  const change = identityChangeOf(result)

  return change ? <IdentityNotice bot={bot} change={change} /> : <></>
}

function IdentityNotice({ bot, change }: { bot: RosterRow; change: IdentityChange }) {
  const b = useBots()
  const undone = useValue($undoneChanges)
  const [state, setState] = useState<NoticeState>('idle')
  const copy = b.onboarding.identity
  const changeId = change.changeId
  const isUndone = Boolean(changeId && undone.has(changeId))

  const undo = async () => {
    if (!changeId || state === 'undoing') {
      return
    }

    setState('undoing')
    const outcome = await undoIdentityChange(bot, changeId)

    if (outcome === 'done') {
      $undoneChanges.set(new Set([...$undoneChanges.get(), changeId]))
      setState('idle')

      return
    }

    setState(outcome === 'stale' ? 'stale' : 'failed')
  }

  return (
    <div className={NOTICE_CLASS} data-slot="identity-change-notice">
      <Codicon className="shrink-0" name="edit" size="0.75rem" />
      <span className="min-w-0 wrap-anywhere">{change.summary}</span>
      {isUndone ? (
        <span data-slot="identity-change-undone">{copy.undone}</span>
      ) : change.undoAvailable && changeId && state !== 'stale' ? (
        <Button
          className="text-[0.75rem] font-medium text-(--ui-text-secondary) underline-offset-2 hover:text-(--ui-text-primary) hover:underline"
          disabled={state === 'undoing'}
          onClick={() => void undo()}
          size="inline"
          type="button"
          variant="text"
        >
          {state === 'undoing' ? copy.undoing : copy.undo}
        </Button>
      ) : null}
      {state === 'stale' ? <span aria-live="polite">{copy.undoStale}</span> : null}
      {state === 'failed' ? <span aria-live="polite">{copy.undoFailed}</span> : null}
    </div>
  )
}

export const identityNoticeContribution = {
  id: 'identity-notice',
  area: TOOL_CARD_AREA,
  data: {
    tools: ['memory'],
    render: (props: ToolCardProps) => <IdentityNoticeCard {...props} />
  }
}
