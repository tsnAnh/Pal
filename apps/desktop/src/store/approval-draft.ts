export interface ApprovalDetail {
  name: string
  value: string
}

export interface ApprovalDraft {
  channel: string
  details: ApprovalDetail[]
  editable: boolean
  expiresAt?: number
  held: boolean
  recipient: string
  state: 'expired' | 'pending'
  subject: string
  text: string
  unviewable: boolean
}

export interface ApprovalDraftExtras {
  choices?: unknown
  details?: unknown
}

const MAX_DETAILS = 50
const MAX_DETAIL_NAME = 120
const MAX_DETAIL_VALUE = 4000

const text = (value: unknown): string => (typeof value === 'string' ? value : '')

function parseDetails(raw: unknown): ApprovalDetail[] {
  if (!Array.isArray(raw)) {
    return []
  }

  const details: ApprovalDetail[] = []

  for (const item of raw) {
    if (details.length >= MAX_DETAILS) {
      break
    }

    if (!item || typeof item !== 'object') {
      continue
    }

    const { name, value } = item as Record<string, unknown>

    if (typeof name !== 'string' || typeof value !== 'string' || !name.trim()) {
      continue
    }

    details.push({ name: name.slice(0, MAX_DETAIL_NAME), value: value.slice(0, MAX_DETAIL_VALUE) })
  }

  return details
}

export function parseApprovalDraft(raw: unknown, extras: ApprovalDraftExtras = {}): ApprovalDraft | undefined {
  if (!raw || typeof raw !== 'object') {
    return undefined
  }

  const draft = raw as Record<string, unknown>

  if (draft.kind !== undefined && draft.kind !== 'outbound_message') {
    return undefined
  }

  return {
    channel: text(draft.channel),
    details: parseDetails(extras.details),
    editable: draft.editable === true,
    expiresAt: typeof draft.expires_at === 'number' ? draft.expires_at : undefined,
    held: draft.held === true,
    recipient: text(draft.recipient),
    state: draft.state === 'expired' ? 'expired' : 'pending',
    subject: text(draft.subject),
    text: text(draft.text),
    unviewable: draft.state !== 'expired' && Array.isArray(extras.choices) && !extras.choices.includes('once')
  }
}

export function parseApprovalScope(raw: unknown): 'bot_chat' | undefined {
  return raw === 'bot_chat' ? 'bot_chat' : undefined
}
