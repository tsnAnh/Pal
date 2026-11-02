import { Button, Codicon, host, TOOL_CARD_AREA, useValue } from '@hermes/plugin-sdk'
import type { ToolCardProps } from '@hermes/plugin-sdk'
import { useCallback, useEffect, useMemo, useState } from 'react'

import { botForChat } from './chat-empty'
import { $botMeta, $lastRoster } from './data'
import { type HandbackAsk, handbackPhase, parseHandbackAsk } from './handback-model'
import { useBots } from './i18n'
import { displayName } from './labels'
import { botRosterMeta } from './routing'
import { type DisplayLease, displayRequest, type DisplayStatus } from './screen-connection'
import { openBotScreen } from './screen-open'
import { useScreenPortalState } from './screen-portal'
import {
  $screenState,
  beginScreenStatusRequest,
  requestScreenTakeover,
  screenStateFor,
  setScreenLease,
  setScreenStatus
} from './screen-state'
import type { RosterRow } from './types'

type Settle = 'cancel' | 'done'

export function HandbackCard({ args, fallback, result, sessionId }: ToolCardProps) {
  const roster = useValue($lastRoster)
  useValue(host.state.focusedStoredSessionId)

  const ask = useMemo(() => parseHandbackAsk(args, result), [args, result])
  const bot = botForChat(roster, sessionId ?? '')

  if (!bot || !ask) {
    return <>{fallback}</>
  }

  return <HandbackCardBody ask={ask} bot={bot} sessionId={sessionId} />
}

function HandbackCardBody({ ask, bot, sessionId }: { ask: HandbackAsk; bot: RosterRow; sessionId: null | string }) {
  const t = useBots()
  const [busy, setBusy] = useState(false)
  const meta = useValue($botMeta)
  useScreenPortalState(bot)
  const state = screenStateFor(useValue($screenState), bot)
  const viewer = state?.viewer ?? null
  const phase = handbackPhase(ask, state?.lease ?? null, viewer, Boolean(state?.unavailable))
  const name = displayName(bot, botRosterMeta(bot, meta) ?? null)

  useEffect(() => {
    let cancelled = false
    const request = beginScreenStatusRequest(bot)

    void displayRequest<DisplayStatus>(bot, 'display.status')
      .then(next => {
        if (!cancelled) {
          setScreenStatus(bot, next, request)
        }
      })
      .catch(() => undefined)

    return () => {
      cancelled = true
    }
  }, [bot, ask.requestedAt])

  const openComputer = useCallback(() => {
    if (phase === 'pending') {
      requestScreenTakeover(bot, ask.reason)
    }

    openBotScreen(bot, botRosterMeta(bot, $botMeta.get()) ?? null)
  }, [ask.reason, bot, phase])

  const settle = useCallback(
    async (kind: Settle) => {
      setBusy(true)

      try {
        if (phase === 'inControl' && viewer) {
          const released = await displayRequest<{ lease: DisplayLease }>(bot, 'display.lease.release', {
            viewer_id: viewer.id
          })

          setScreenLease(bot, released.lease)
        }

        const resolved = await displayRequest<{ lease: DisplayLease }>(bot, 'display.lease.resolve', {
          ask_at: ask.requestedAt
        })

        setScreenLease(bot, resolved.lease)
      } catch {
        host.notify({ kind: 'error', message: t.handback.actionFailed })
        setBusy(false)

        return
      }

      const message = kind === 'done' ? t.handback.continueMessage : t.handback.cancelMessage

      const sent =
        typeof host.composer?.submit === 'function' && sessionId ? host.composer.submit(sessionId, message) : false

      if (!sent) {
        host.notify({ kind: 'error', message: t.handback.sendFailed(name) })
      }

      setBusy(false)
    },
    [ask.requestedAt, bot, name, phase, sessionId, t, viewer]
  )

  const settled = phase === 'resolved'
  const actionable = phase === 'pending' || phase === 'inControl' || phase === 'elsewhere'

  return (
    <div
      className="my-1.5 flex max-w-lg flex-col gap-2.5 rounded-xl bg-(--ui-bg-tertiary) px-3.5 py-3"
      data-handback-phase={phase}
      data-slot="handback-card"
    >
      <div className="flex min-w-0 items-start gap-2.5">
        <Codicon className="mt-0.5 text-(--ui-text-tertiary)" name={settled ? 'check' : 'device-desktop'} />
        <div className="grid min-w-0 gap-0.5">
          <span className="text-[0.68rem] font-medium uppercase tracking-wide text-(--ui-text-tertiary)">
            {settled ? t.handback.resolved : t.handback.needsYou}
          </span>
          <span className="break-words text-(--ui-text-primary)">{ask.reason}</span>
          {phase === 'inControl' ? (
            <span className="text-xs text-(--ui-text-tertiary)">{t.handback.inControl}</span>
          ) : phase === 'elsewhere' ? (
            <span className="text-xs text-(--ui-text-tertiary)">{t.handback.elsewhere}</span>
          ) : null}
        </div>
      </div>
      {actionable ? (
        <div className="flex flex-wrap items-center gap-2 pl-6">
          {phase !== 'inControl' ? (
            <Button disabled={busy} onClick={openComputer} size="sm">
              <Codicon name="device-desktop" /> {t.handback.openComputer}
            </Button>
          ) : null}
          {phase !== 'elsewhere' ? (
            <Button
              disabled={busy}
              onClick={() => void settle('done')}
              size="sm"
              variant={phase === 'inControl' ? 'default' : 'secondary'}
            >
              <Codicon name="check" /> {t.handback.done}
            </Button>
          ) : null}
          <Button disabled={busy} onClick={() => void settle('cancel')} size="sm" variant="ghost">
            {t.handback.cancel}
          </Button>
        </div>
      ) : null}
    </div>
  )
}

export const handbackCardContribution = {
  id: 'handback-card',
  area: TOOL_CARD_AREA,
  data: {
    tools: ['request_handback'],
    render: (props: ToolCardProps) => <HandbackCard {...props} />
  }
}
