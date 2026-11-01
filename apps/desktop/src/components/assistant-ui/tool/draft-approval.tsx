'use client'

import { useStore } from '@nanostores/react'
import { type FC, useCallback, useRef, useState } from 'react'

import { Button } from '@/components/ui/button'
import type { CardStackAction } from '@/components/ui/card-stack'
import { Codicon } from '@/components/ui/codicon'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog'
import { Textarea } from '@/components/ui/textarea'
import { useI18n } from '@/i18n'
import { Loader2 } from '@/lib/icons'
import { releaseApprovalKey } from '@/lib/keybinds/approval-keys'
import type { ApprovalDraft } from '@/store/approval-draft'
import { $gateway } from '@/store/gateway'
import { reconnectAction } from '@/store/gateway-reconnect'
import { notifyError } from '@/store/notifications'
import { type ApprovalRequest, sessionApprovalRequests } from '@/store/prompts'

type DraftChoice = 'deny' | 'once'

interface DraftApprovalCardProps {
  position: number
  request: ApprovalRequest
  send: (request: ApprovalRequest, choice: DraftChoice, editedText?: string) => Promise<void>
  stack: CardStackAction
  total: number
}

interface DraftAnswer {
  busy: boolean
  respond: (choice: DraftChoice) => Promise<void>
  submitting: DraftChoice | null
}

function useDraftAnswer(
  request: ApprovalRequest,
  stack: CardStackAction,
  send: DraftApprovalCardProps['send'],
  editedText: string | undefined
): DraftAnswer {
  const { t } = useI18n()
  const copy = t.assistant.approval
  const gateway = useStore($gateway)
  const [submitting, setSubmitting] = useState<DraftChoice | null>(null)
  const submittingRef = useRef(false)

  const respond = useCallback(
    async (choice: DraftChoice) => {
      const pending = sessionApprovalRequests(request.sessionId).get()

      if (submittingRef.current || !pending.some(item => item.requestId === request.requestId)) {
        return
      }

      if (!gateway) {
        notifyError(new Error(copy.gatewayDisconnected), copy.sendFailed, { action: reconnectAction() })

        return
      }

      submittingRef.current = true
      setSubmitting(choice)

      try {
        await stack.depart(() => send(request, choice, choice === 'once' ? editedText : undefined))
      } catch (error) {
        releaseApprovalKey()
        notifyError(error, copy.sendFailed)
        submittingRef.current = false
        setSubmitting(null)
      }
    },
    [copy.gatewayDisconnected, copy.sendFailed, editedText, gateway, request, send, stack]
  )

  return { busy: submitting !== null || !stack.active || stack.busy, respond, submitting }
}

interface DraftBodyProps {
  busy: boolean
  draft: ApprovalDraft
  editing: boolean
  onText: (text: string) => void
  text: string
}

const DraftBody: FC<DraftBodyProps> = ({ busy, draft, editing, onText, text }) => {
  const { t } = useI18n()
  const copy = t.assistant.approval

  return editing ? (
    <Textarea
      aria-label={copy.draftEditLabel}
      className="mx-2.5 mt-2 max-h-48 w-[calc(100%-1.25rem)] text-xs leading-relaxed"
      data-slot="tool-draft-editor"
      disabled={busy}
      onChange={event => onText(event.target.value)}
      value={text}
    />
  ) : (
    <pre
      className="m-0 max-h-40 overflow-auto whitespace-pre-wrap break-words px-2.5 py-2 font-sans text-xs leading-relaxed text-(--ui-text-primary)"
      data-slot="tool-draft-text"
    >
      {draft.text}
    </pre>
  )
}

const DraftDetails: FC<{ details: ApprovalDraft['details'] }> = ({ details }) => {
  if (details.length === 0) {
    return null
  }

  return (
    <dl
      className="m-0 mx-2.5 mt-1 grid max-h-32 grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-0.5 overflow-auto text-[0.6875rem] leading-relaxed"
      data-slot="tool-draft-details"
    >
      {details.map(({ name, value }, index) => (
        <div className="contents" key={`${name}-${index}`}>
          <dt className="text-(--ui-text-tertiary)">{name}</dt>
          <dd className="m-0 whitespace-pre-wrap break-words text-(--ui-text-secondary)">{value}</dd>
        </div>
      ))}
    </dl>
  )
}

interface DraftActionsProps {
  answer: DraftAnswer
  canSend: boolean
  draft: ApprovalDraft
  edited: boolean
  editing: boolean
  onToggleEdit: () => void
}

const DraftActions: FC<DraftActionsProps> = ({ answer, canSend, draft, edited, editing, onToggleEdit }) => {
  const { t } = useI18n()
  const copy = t.assistant.approval
  const expired = draft.state === 'expired'
  const spinner = <Loader2 className="size-3 animate-spin" />
  const sendLabel = edited ? copy.draftSendEdited : copy.draftSend

  return (
    <div className="flex items-center justify-end gap-1.5 px-2 pb-2 pt-1" data-slot="tool-draft-actions">
      <Button
        data-draft-discard=""
        disabled={answer.busy}
        onClick={() => void answer.respond('deny')}
        size="sm"
        variant="text"
      >
        {answer.submitting === 'deny' ? spinner : copy.draftDiscard}
      </Button>
      {draft.editable && !expired && !draft.unviewable && (
        <Button data-draft-edit="" disabled={answer.busy} onClick={onToggleEdit} size="sm" variant="secondary">
          {editing ? copy.draftCancelEdit : copy.draftEdit}
        </Button>
      )}
      {!expired && !draft.unviewable && (
        <Button
          data-draft-send=""
          disabled={answer.busy || !canSend}
          onClick={() => void answer.respond('once')}
          size="sm"
        >
          {answer.submitting === 'once' ? spinner : sendLabel}
        </Button>
      )}
    </div>
  )
}

export const DraftApprovalCard: FC<DraftApprovalCardProps> = ({ position, request, send, stack, total }) => {
  const { t } = useI18n()
  const copy = t.assistant.approval
  const draft = request.draft
  const original = draft?.text ?? ''
  const [editing, setEditing] = useState(false)
  const [text, setText] = useState(original)
  const [baseline, setBaseline] = useState(original)

  if (original !== baseline) {
    setBaseline(original)

    if (text === baseline) {
      setText(original)
    }
  }

  const edited = editing && text !== original
  const answer = useDraftAnswer(request, stack, send, edited ? text : undefined)

  if (!draft) {
    return null
  }

  const expired = draft.state === 'expired'

  const route = [draft.recipient && copy.draftTo(draft.recipient), draft.channel && copy.draftVia(draft.channel)]
    .filter(Boolean)
    .join(' · ')

  return (
    <article
      aria-hidden={!stack.active || undefined}
      className="min-w-0"
      data-draft-state={draft.state}
      data-request-id={request.requestId}
      data-slot="tool-draft-card"
      inert={!stack.active}
    >
      <div className="flex items-center gap-2 px-2.5 pt-2 text-xs text-(--ui-text-secondary)">
        <Codicon name="mail" size="0.875rem" />
        <span>{copy.draftTitle}</span>
        {total > 1 && (
          <span className="ml-auto text-[0.6875rem] tabular-nums text-(--ui-text-tertiary)">
            {position} / {total}
          </span>
        )}
      </div>
      {route && <div className="px-2.5 pt-1 text-xs text-(--ui-text-primary)">{route}</div>}
      {draft.subject && (
        <div className="px-2.5 pt-0.5 text-xs text-(--ui-text-secondary)">{copy.draftSubject(draft.subject)}</div>
      )}
      <DraftBody busy={answer.busy} draft={draft} editing={editing} onText={setText} text={text} />
      <DraftDetails details={draft.details} />
      {(expired || draft.held || draft.unviewable) && (
        <div className="px-2.5 pb-1 pt-1 text-[0.6875rem] text-(--ui-text-tertiary)" data-slot="tool-draft-note">
          {expired ? copy.draftExpired : draft.unviewable ? copy.draftUnviewable : copy.draftHeld}
        </div>
      )}
      <DraftActions
        answer={answer}
        canSend={!expired && (!editing || text.trim().length > 0)}
        draft={draft}
        edited={edited}
        editing={editing}
        onToggleEdit={() => {
          setText(original)
          setEditing(value => !value)
        }}
      />
    </article>
  )
}

interface BotChatApprovalActionsProps {
  allowAlways: boolean
  busy: boolean
  description: string
  onAnswer: (choice: 'always' | 'deny' | 'once') => void
  submitting: string | null
}

export const BotChatApprovalActions: FC<BotChatApprovalActionsProps> = ({
  allowAlways,
  busy,
  description,
  onAnswer,
  submitting
}) => {
  const { t } = useI18n()
  const copy = t.assistant.approval
  const [confirming, setConfirming] = useState(false)
  const spinner = <Loader2 className="size-3 animate-spin" />

  return (
    <>
      <Button data-approval-deny="" disabled={busy} onClick={() => onAnswer('deny')} size="sm" variant="text">
        {submitting === 'deny' ? spinner : copy.deny}
      </Button>
      {allowAlways && (
        <Button
          data-approval-always=""
          disabled={busy}
          onClick={() => setConfirming(true)}
          size="sm"
          variant="secondary"
        >
          {submitting === 'always' ? spinner : copy.alwaysAllow}
        </Button>
      )}
      <Button data-approval-run="" disabled={busy} onClick={() => onAnswer('once')} size="sm">
        {submitting === 'once' ? spinner : copy.allowOnce}
        <span className="opacity-60">↵</span>
      </Button>
      <Dialog onOpenChange={setConfirming} open={confirming}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{copy.alwaysTitle}</DialogTitle>
            <DialogDescription>{copy.alwaysDescriptionBot(description)}</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button onClick={() => setConfirming(false)} size="sm" variant="ghost">
              {t.common.cancel}
            </Button>
            <Button
              onClick={() => {
                setConfirming(false)
                onAnswer('always')
              }}
              size="sm"
              variant="destructive"
            >
              {copy.alwaysAllow}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}
