import { useCallback } from 'react'

import { withSessionNotFoundResume } from '@/app/session/hooks/use-prompt-actions/utils'
import type { HermesGateway } from '@/hermes'
import { useI18n } from '@/i18n'
import { cn } from '@/lib/utils'
import { parkQueuedPrompts } from '@/store/composer-queue'
import { notifyError } from '@/store/notifications'

interface BotStopNowProps {
  className?: string
  label: string
  onStop: () => void
}

export function BotStopNow({ className, label, onStop }: BotStopNowProps) {
  return (
    <button
      className={cn(
        'pointer-events-auto ml-2 h-7 shrink-0 rounded-full border border-(--ui-stroke-tertiary) bg-(--ui-chat-surface-background)/80 px-3 text-xs font-medium text-foreground backdrop-blur-md [-webkit-app-region:no-drag] hover:bg-(--ui-control-hover-background)',
        className
      )}
      data-slot="bot-stop-now"
      onClick={onStop}
      type="button"
    >
      {label}
    </button>
  )
}

type OwnerRequest = <T>(method: string, params?: Record<string, unknown>) => Promise<T>

interface ChatHaltOptions {
  activeSessionId: null | string
  gateway: HermesGateway | null
  onCancel: () => Promise<void> | void
  queueSessionKey: null | string | undefined
  request?: OwnerRequest
}

/** `haltRun`: transcript-side stops are explicit halts like the composer's Stop, so queued turns are parked
 *  and the interrupt does not roll into the next one. `stopNow`: the same halt plus the /stop command's
 *  other half, ending the session's background processes, delegations and bot-to-bot handoffs, which a
 *  plain interrupt leaves running. */
export function useChatHalt({ activeSessionId, gateway, onCancel, queueSessionKey, request }: ChatHaltOptions) {
  const { t } = useI18n()

  const haltRun = useCallback(() => {
    parkQueuedPrompts(queueSessionKey || activeSessionId)

    return onCancel()
  }, [activeSessionId, onCancel, queueSessionKey])

  const stopNow = useCallback(async () => {
    try {
      await haltRun()
    } catch (err) {
      notifyError(err, t.desktop.stopFailed)
    }

    const send: OwnerRequest | null = request ?? (gateway ? (method, params) => gateway.request(method, params) : null)

    if (!activeSessionId || !send) {
      return
    }

    try {
      await withSessionNotFoundResume(
        activeSessionId,
        queueSessionKey,
        liveId => send('process.stop', { session_id: liveId }),
        { requestGateway: send }
      )
    } catch (err) {
      notifyError(err, t.desktop.stopFailed)
    }
  }, [activeSessionId, gateway, haltRun, queueSessionKey, request, t.desktop.stopFailed])

  return { haltRun, stopNow }
}
