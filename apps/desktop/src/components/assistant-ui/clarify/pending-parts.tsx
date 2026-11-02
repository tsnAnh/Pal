import { useI18n } from '@/i18n'
import { MessageQuestion } from '@/lib/icons'
import { reconnectAction } from '@/store/gateway-reconnect'
import { notifyError } from '@/store/notifications'

import { CLARIFY_ICON_CLASS } from './core/shell'

export function ClarifyProgress({ answered, total }: { answered: number; total: number }) {
  const { t } = useI18n()
  const copy = t.assistant.clarify

  return (
    <div className="flex items-start gap-2">
      <span className="flex-1 text-[0.6875rem] leading-4 text-(--ui-text-tertiary)">
        {total === 1 ? copy.oneQuestion : copy.questionProgress(answered, total)}
      </span>
      <MessageQuestion aria-hidden className={CLARIFY_ICON_CLASS} />
    </div>
  )
}

export function ClarifyLoadingStatus({ ready, undelivered }: { ready: boolean; undelivered: boolean }) {
  const { t } = useI18n()

  if (ready || undelivered) {
    return null
  }

  return (
    <span className="sr-only" role="status">
      {t.assistant.clarify.loadingQuestion}
    </span>
  )
}

export function notifyUnavailable(
  copy: { gatewayDisconnected: string; notReady: string; sendFailed: string },
  hasRequest: boolean
) {
  notifyError(
    new Error(hasRequest ? copy.gatewayDisconnected : copy.notReady),
    copy.sendFailed,
    hasRequest ? { action: reconnectAction() } : {}
  )
}
