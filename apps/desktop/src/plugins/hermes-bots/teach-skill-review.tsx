/**
 * The owner's review of the draft skill the bot wrote from a demonstration: read the SKILL.md, then Approve (the
 * only thing that turns it on), Edit, or Discard. The draft is the backend's file; this dialog never assumes it
 * exists: it asks for it on open and says so while the bot is still writing.
 */

import { Button, Codicon, ConfirmDialog, Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, GlyphSpinner, host, Textarea } from '@hermes/plugin-sdk'
import type { BotTeachDraft, BotTeachPending } from '@hermes/plugin-sdk'
import { useCallback, useEffect, useState } from 'react'

import { useTeach } from './teach-i18n'
import { approveDraft, discardDraft, loadDraft, saveDraft } from './teach-skill-actions'
import { teachErrorCode } from './teach-skill-model'
import type { RosterRow } from './types'

const AUTHORING_ERRORS = new Set(['invalid_skill', 'skill_write_failed'])

/** An error whose message is already user-facing copy. */
class ShownError extends Error {}

function failureMessage(error: unknown, fallback: string): string {
  if (error instanceof ShownError) {
    return error.message
  }

  const message = (error as { message?: unknown } | null)?.message

  return AUTHORING_ERRORS.has(teachErrorCode(error)) && typeof message === 'string' && message ? message : fallback
}

export function TeachConfirmDiscard({
  onClose,
  onConfirm,
  open
}: {
  onClose: () => void
  onConfirm: () => Promise<void>
  open: boolean
}) {
  const t = useTeach()

  return (
    <ConfirmDialog
      confirmLabel={t.draft.discard}
      description={t.draft.discardBody}
      destructive
      dismissOnConfirm
      onClose={onClose}
      onConfirm={onConfirm}
      open={open}
      title={t.draft.discardTitle}
    />
  )
}

interface ReviewProps {
  bot: RosterRow
  name: string
  onClose: () => void
  onSettled: () => Promise<unknown> | void
  open: boolean
  pending: BotTeachPending
}

export function TeachReviewDialog({ bot, name, onClose, onSettled, open, pending }: ReviewProps) {
  const t = useTeach()
  const [draft, setDraft] = useState<BotTeachDraft | null>(null)
  const [text, setText] = useState('')
  const [editing, setEditing] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<null | string>(null)
  const [discarding, setDiscarding] = useState(false)
  const teachId = pending.teach_id

  useEffect(() => {
    if (!open) {
      return
    }

    let cancelled = false
    setDraft(null)
    setEditing(false)
    setError(null)

    void loadDraft(bot, teachId)
      .then(next => {
        if (!cancelled) {
          setDraft(next)
          setText(next.content ?? '')
        }
      })
      .catch(() => {
        if (!cancelled) {
          setError(t.draft.loadFailed)
        }
      })

    return () => {
      cancelled = true
    }
  }, [bot, open, t.draft.loadFailed, teachId])

  const ready = draft?.state === 'ready' && draft.content !== null
  const extraFiles = draft?.extra_files ?? []
  const changed = editing && ready && text !== draft?.content

  const run = useCallback(
    async (work: () => Promise<void>, fallback: string) => {
      setBusy(true)
      setError(null)

      try {
        await work()
      } catch (failure) {
        setError(failureMessage(failure, fallback))
      } finally {
        setBusy(false)
      }
    },
    []
  )

  const save = () =>
    run(async () => {
      const saved = await saveDraft(bot, teachId, text)
      setDraft(saved)
      setText(saved.content ?? text)
      setEditing(false)
    }, t.draft.saveFailed)

  const approve = () =>
    run(async () => {
      if (!draft?.content_hash && !changed) {
        throw new ShownError(t.draft.notReady)
      }

      try {
        const approved = await approveDraft(
          bot,
          teachId,
          changed ? { content: text } : { contentHash: draft?.content_hash ?? '' }
        )

        host.notify({ kind: 'success', message: t.draft.approved(approved.skill_name) })
        await onSettled()
        onClose()
      } catch (failure) {
        if (teachErrorCode(failure) === 'draft_changed') {
          const fresh = await loadDraft(bot, teachId)
          setDraft(fresh)
          setText(fresh.content ?? '')
          setEditing(false)

          throw new ShownError(t.draft.changed)
        }

        throw failure
      }
    }, t.draft.approveFailed)

  const discard = async () => {
    try {
      await discardDraft(bot, teachId)
    } catch (failure) {
      setError(failureMessage(failure, t.draft.discardFailed))

      throw failure
    }

    host.notify({ kind: 'info', message: t.draft.discarded })
    await onSettled()
    onClose()
  }

  return (
    <Dialog onOpenChange={next => !next && !busy && onClose()} open={open}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>{t.draft.title}</DialogTitle>
          <DialogDescription>{t.draft.description(name)}</DialogDescription>
        </DialogHeader>
        {draft && !ready ? (
          <div className="py-6 text-center text-xs text-muted-foreground">{t.draft.notReady}</div>
        ) : null}
        {!draft && !error ? (
          <div className="flex items-center justify-center gap-2 py-6 text-xs text-muted-foreground">
            <GlyphSpinner /> {t.draft.loading}
          </div>
        ) : null}
        {ready ? (
          <Textarea
            aria-label={t.draft.title}
            className="max-h-[50vh] min-h-72 font-mono text-xs"
            onChange={event => setText(event.target.value)}
            readOnly={!editing}
            spellCheck={false}
            value={text}
          />
        ) : null}
        <div className="grid gap-0.5 text-xs text-muted-foreground">
          <span>{t.draft.privacy}</span>
          {draft?.truncated ? <span>{t.draft.truncated}</span> : null}
          {extraFiles.length ? <span className="text-amber-600 dark:text-amber-400">{t.draft.extraFiles(extraFiles.join(', '))}</span> : null}
        </div>
        {error ? (
          <div className="text-xs text-red-500" role="alert">
            {error}
          </div>
        ) : null}
        <DialogFooter>
          <Button disabled={busy} onClick={() => setDiscarding(true)} variant="ghost">
            {t.draft.discard}
          </Button>
          {editing ? (
            <>
              <Button
                disabled={busy}
                onClick={() => {
                  setText(draft?.content ?? '')
                  setEditing(false)
                }}
                variant="secondary"
              >
                {t.draft.cancelEdit}
              </Button>
              <Button disabled={busy || !changed} onClick={() => void save()} variant="secondary">
                {t.draft.save}
              </Button>
            </>
          ) : (
            <Button disabled={busy || !ready} onClick={() => setEditing(true)} variant="secondary">
              <Codicon name="edit" /> {t.draft.edit}
            </Button>
          )}
          <Button disabled={busy || !ready || extraFiles.length > 0} onClick={() => void approve()}>
            {busy ? <GlyphSpinner /> : <Codicon name="check" />} {t.draft.approve}
          </Button>
        </DialogFooter>
        <TeachConfirmDiscard onClose={() => setDiscarding(false)} onConfirm={discard} open={discarding} />
      </DialogContent>
    </Dialog>
  )
}
