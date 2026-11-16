import { isBotChatSession } from '@/store/session-states'

const ADMISSION_RECEIPT_STATUSES: ReadonlySet<string> = new Set([
  'queued',
  'started',
  'steered',
  'terminal',
  'turn',
  'unknown'
])

const TRACKED_RECEIPT_STATUS: Readonly<Record<string, string>> = { steered: 'queued', turn: 'started' }

export const isAdmissionReceiptStatus = (status: string | undefined): boolean =>
  ADMISSION_RECEIPT_STATUSES.has(status ?? '')

export const trackedReceiptStatus = (status: string | undefined): string | undefined =>
  status === undefined ? undefined : (TRACKED_RECEIPT_STATUS[status] ?? status)

export const isQueuedSend = (
  fromQueue: boolean | undefined,
  queueAdmission: boolean,
  sessionId: string | null | undefined
) => Boolean(fromQueue) || (queueAdmission && !isBotChatSession(sessionId))
