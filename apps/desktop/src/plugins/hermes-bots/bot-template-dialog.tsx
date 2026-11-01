import {
  Button,
  Codicon,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DropdownMenuItem,
  GlyphSpinner,
  host,
  Input,
  isSubmitEnter,
  useI18n,
  useValue
} from '@hermes/plugin-sdk'
import { useEffect, useRef, useState } from 'react'

import {
  $botTemplateFile,
  closeBotTemplateImport,
  importTemplate,
  openImportedBot,
  reviewTemplate,
  startBotTemplateImport,
  type TemplateFailure,
  templateFailure,
  type TemplateReview,
  templateSlug,
  useBotTemplateSupport
} from './bot-template'
import type { BotTemplateMessages } from './bot-template-locales'
import { labeled } from './dialog-parts'
import { useBots } from './i18n'

type Phase =
  { failure: TemplateFailure; kind: 'failed' } | { kind: 'ready'; review: TemplateReview } | { kind: 'reviewing' }

export function templateFailureCopy(copy: BotTemplateMessages, failure: TemplateFailure): string {
  switch (failure) {
    case 'changed':
      return copy.failureChanged

    case 'invalid':
      return copy.failureInvalid

    case 'name-taken':
      return copy.failureNameTaken

    case 'newer':
      return copy.failureNewer

    case 'too-large':
      return copy.failureTooLarge

    case 'unsupported':
      return copy.failureUnsupported

    default:
      return copy.failureGeneric
  }
}

export function BotTemplateImportMenuItem() {
  const b = useBots()

  if (useBotTemplateSupport(true) !== 'supported') {
    return null
  }

  return (
    <DropdownMenuItem
      onSelect={() =>
        void startBotTemplateImport().then(failure => {
          if (failure) {
            host.notify({ kind: 'error', message: templateFailureCopy(b.template, failure) })
          }
        })
      }
    >
      <Codicon className="mr-1.5" name="package" />
      {b.template.importAction}
    </DropdownMenuItem>
  )
}

function abilityLines(copy: BotTemplateMessages, review: TemplateReview): string[] {
  const skills = review.skills ?? []
  const lines = [review.toolsets?.length ? copy.useTools(review.toolsets.join(', ')) : copy.useDefaultTools]

  if (skills.length) {
    lines.push(copy.useSkills(skills.length))
  }

  if (skills.some(skill => skill.has_scripts)) {
    lines.push(copy.skillScripts)
  }

  for (const server of review.mcp_servers ?? []) {
    lines.push(
      server.transport === 'stdio'
        ? copy.serverLocal(server.name, server.command ?? '')
        : copy.serverRemote(server.name, server.url ?? '', (server.transport ?? 'http').toUpperCase())
    )

    if (server.needs?.length) {
      lines.push(copy.serverNeeds(server.needs.join(', ')))
    }
  }

  if (review.mcp_servers?.length) {
    lines.push(copy.serversOff)
  }

  if (review.routines?.length) {
    lines.push(copy.routines(review.routines.length), copy.routinesPaused)
  }

  if (review.model?.default) {
    lines.push(copy.useModel(review.model.default))
  }

  return lines
}

function ReviewBody({ review }: { review: TemplateReview }) {
  const b = useBots()
  const lines = abilityLines(b.template, review)
  const routines = review.routines ?? []
  const skills = review.skills ?? []
  const skipped = review.skipped_routines ?? []

  return (
    <div className="grid max-h-[26rem] min-h-0 gap-3 overflow-y-auto overscroll-contain pr-1">
      <div className="grid gap-1.5">
        <p className="text-xs font-medium text-(--ui-text-secondary)">{b.template.abilitiesHeading}</p>
        <ul className="grid gap-1 text-sm">
          {lines.map(line => (
            <li className="text-(--ui-text-primary)" key={line}>
              {line}
            </li>
          ))}
        </ul>
        {skills.length ? (
          <p className="pl-3 text-xs text-(--ui-text-tertiary)">{skills.map(skill => skill.name).join(', ')}</p>
        ) : null}
        {routines.length ? (
          <ul className="grid gap-0.5 pl-3 text-xs text-(--ui-text-tertiary)">
            {routines.map(routine => (
              <li key={`${routine.name}:${routine.schedule}`}>{`${routine.name} · ${routine.schedule}`}</li>
            ))}
          </ul>
        ) : null}
        {skipped.length ? (
          <p className="text-xs text-(--ui-text-tertiary)">{b.template.skippedRoutines(skipped.join(', '))}</p>
        ) : null}
      </div>
      <div className="grid gap-1.5">
        <p className="text-xs font-medium text-(--ui-text-secondary)">{b.template.instructionsHeading}</p>
        {review.soul?.trim() ? (
          <div className="max-h-40 overflow-y-auto rounded-md border border-(--ui-stroke-secondary) px-2.5 py-2 text-xs whitespace-pre-wrap text-(--ui-text-secondary)">
            {review.soul}
          </div>
        ) : (
          <p className="text-xs text-(--ui-text-tertiary)">{b.template.noInstructions}</p>
        )}
      </div>
      <p className="text-xs text-(--ui-text-tertiary)">{b.template.privacyNote}</p>
    </div>
  )
}

export function BotTemplateImportDialog() {
  const { t } = useI18n()
  const b = useBots()
  const file = useValue($botTemplateFile)
  const [phase, setPhase] = useState<Phase>({ kind: 'reviewing' })
  const [name, setName] = useState('')
  const [busy, setBusy] = useState(false)
  const [failure, setFailure] = useState<null | TemplateFailure>(null)
  const token = useRef(0)

  useEffect(() => {
    if (!file) {
      return
    }

    const mine = ++token.current
    setPhase({ kind: 'reviewing' })
    setFailure(null)
    setBusy(false)

    reviewTemplate(file.data).then(
      review => {
        if (token.current === mine) {
          setName(review.suggested_display_name)
          setPhase({ kind: 'ready', review })
        }
      },
      error => {
        if (token.current === mine) {
          setPhase({ failure: templateFailure(error), kind: 'failed' })
        }
      }
    )

    const requests = token

    return () => {
      requests.current++
    }
  }, [file])

  const review = phase.kind === 'ready' ? phase.review : null
  const shown = name.trim()
  const slug = review ? (shown === review.suggested_display_name ? review.suggested_name : templateSlug(shown)) : null
  const canImport = Boolean(review && slug && shown && !busy && failure !== 'changed')

  const submit = async () => {
    if (!file || !review || !slug || !canImport) {
      return
    }

    const mine = ++token.current
    setBusy(true)
    setFailure(null)

    try {
      const result = await importTemplate(file, review, { displayName: shown, name: slug })
      const created = result.name || slug
      const label = result.display_name || shown
      const { needsModel } = await openImportedBot(created)

      if (token.current === mine) {
        closeBotTemplateImport()
      }

      host.notify(
        needsModel
          ? { kind: 'warning', message: b.template.needsModel, title: b.template.imported(label) }
          : { kind: 'success', message: b.template.imported(label) }
      )
    } catch (error) {
      if (token.current === mine) {
        setFailure(templateFailure(error))
        setBusy(false)
      }
    }
  }

  return (
    <Dialog onOpenChange={next => !next && !busy && closeBotTemplateImport()} open={file !== null}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>{b.template.importTitle}</DialogTitle>
          <DialogDescription>{b.template.importDescription}</DialogDescription>
        </DialogHeader>
        {phase.kind === 'reviewing' ? (
          <div className="flex min-h-24 items-center justify-center" role="status">
            <GlyphSpinner className="text-(--ui-text-tertiary)" spinner="breathe" />
            <span className="sr-only">{b.template.reviewLabel}</span>
          </div>
        ) : null}
        {phase.kind === 'failed' ? (
          <p className="text-sm text-destructive" role="alert">
            {templateFailureCopy(b.template, phase.failure)}
          </p>
        ) : null}
        {review ? (
          <div className="grid gap-3">
            {labeled(
              b.template.nameLabel,
              <Input
                aria-label={b.template.nameLabel}
                disabled={busy}
                maxLength={64}
                onChange={event => setName(event.target.value)}
                onKeyDown={event => {
                  if (isSubmitEnter(event)) {
                    event.preventDefault()
                    void submit()
                  }
                }}
                value={name}
              />
            )}
            <ReviewBody review={review} />
            {failure ? (
              <p className="text-xs text-destructive" role="alert">
                {templateFailureCopy(b.template, failure)}
              </p>
            ) : null}
          </div>
        ) : null}
        <DialogFooter>
          <Button disabled={busy} onClick={closeBotTemplateImport} type="button" variant="ghost">
            {t.common.cancel}
          </Button>
          {review ? (
            <Button disabled={!canImport} onClick={() => void submit()} type="button">
              {busy ? b.template.importing : b.template.confirm}
            </Button>
          ) : null}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
