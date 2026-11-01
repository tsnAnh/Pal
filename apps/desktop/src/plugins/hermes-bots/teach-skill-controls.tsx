/**
 * Teach a skill, on the bot's Screen pane: the toolbar control (Teach → recording indicator with Stop) and the
 * banner for the draft the bot writes afterwards. Both read `bot.teach.status`, the backend's truth, through one
 * poller that runs only while something is moving (a recording, or a draft being written).
 */

import { Button, Codicon, host, Tip, useValue } from '@hermes/plugin-sdk'
import type { DisplayLease } from '@hermes/plugin-sdk'
import { useCallback, useEffect, useState } from 'react'

import { $botMeta } from './data'
import { displayName } from './labels'
import { botRosterMeta } from './routing'
import { isDisplayUnavailable, type ScreenViewer } from './screen-connection'
import { useTeach } from './teach-i18n'
import { askAgain, beginTeaching, discardDraft, fetchTeachStatus, finishTeaching } from './teach-skill-actions'
import { formatClock, pendingOf, pollDelay, secondsLeft, teachErrorCode, teachPhase } from './teach-skill-model'
import { TeachConfirmDiscard, TeachReviewDialog } from './teach-skill-review'
import { $teachState, askAgainWaitsUntil, setTeachStatus, setTeachUnavailable, teachStateFor } from './teach-skill-state'
import type { RosterRow } from './types'

interface TeachControlsProps {
  bot: RosterRow
  lease: DisplayLease | null
  live: boolean
  viewer: null | ScreenViewer
}

function useBotName(bot: RosterRow): string {
  const meta = useValue($botMeta)

  return displayName(bot, botRosterMeta(bot, meta) ?? null)
}

function useNow(active: boolean): number {
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    if (!active) {
      return
    }

    setNow(Date.now())
    const id = window.setInterval(() => setNow(Date.now()), 1000)

    return () => window.clearInterval(id)
  }, [active])

  return now
}

/** Ask the backend once when the pane goes live, then again only while a recording or a draft is moving. */
function useTeachPolling(bot: RosterRow, live: boolean): void {
  const state = teachStateFor(useValue($teachState), bot)
  const delay = pollDelay(state?.snapshot?.status ?? null)
  const known = state !== null

  const refresh = useCallback(async () => {
    try {
      setTeachStatus(bot, await fetchTeachStatus(bot))
    } catch (error) {
      if (isDisplayUnavailable(error)) {
        setTeachUnavailable(bot)
      }
    }
  }, [bot])

  useEffect(() => {
    if (live && !known) {
      void refresh()
    }
  }, [known, live, refresh])

  useEffect(() => {
    if (!live || delay === null) {
      return
    }

    const id = window.setTimeout(() => void refresh(), delay)

    return () => window.clearTimeout(id)
  }, [delay, live, refresh, state?.snapshot])
}

export function TeachSkillControls({ bot, lease, live, viewer }: TeachControlsProps) {
  const t = useTeach()
  const name = useBotName(bot)
  useTeachPolling(bot, live)
  const snapshot = teachStateFor(useValue($teachState), bot)?.snapshot ?? null
  const phase = teachPhase(snapshot, live)
  const now = useNow(phase === 'recording')
  const [busy, setBusy] = useState(false)

  const refresh = useCallback(
    () => fetchTeachStatus(bot).then(next => setTeachStatus(bot, next)).catch(() => undefined),
    [bot]
  )

  const begin = useCallback(async () => {
    if (!viewer) {
      return
    }

    setBusy(true)

    try {
      setTeachStatus(bot, await beginTeaching(bot, viewer, lease, t.leaseReason))
    } catch (error) {
      const code = teachErrorCode(error) as keyof typeof t.startRefused
      host.notify({ kind: 'error', message: t.startRefused[code] ?? t.startFailed })
      await refresh()
    } finally {
      setBusy(false)
    }
  }, [bot, lease, refresh, t, viewer])

  const end = useCallback(
    async (discard: boolean) => {
      setBusy(true)

      try {
        const outcome = await finishTeaching(bot, viewer, { discard })

        if (outcome.kind === 'empty' && !discard) {
          host.notify({ kind: 'info', message: t.nothingRecorded })
        } else if (outcome.kind === 'unsent') {
          host.notify({ kind: 'error', message: outcome.reason === 'no_chat' ? t.openChatFirst(name) : t.sendFailed(name) })
        }
      } catch {
        host.notify({ kind: 'error', message: t.stopFailed })
      } finally {
        await refresh()
        setBusy(false)
      }
    },
    [bot, name, refresh, t, viewer]
  )

  if (phase === 'idle') {
    return (
      <Tip label={t.startHint(name)}>
        <Button disabled={busy || !viewer} onClick={() => void begin()} size="sm" variant="secondary">
          <Codicon name="mortar-board" /> {t.start}
        </Button>
      </Tip>
    )
  }

  if (phase === 'recording' && snapshot) {
    return (
      <>
        <span
          className="flex items-center gap-1.5 rounded bg-red-500/15 px-2 py-0.5 font-medium text-red-600 dark:text-red-400"
          data-slot="teach-recording"
          role="status"
        >
          <span aria-hidden className="size-1.5 rounded-full bg-red-500 motion-safe:animate-pulse" />
          {t.recording} · {t.timeLeft(formatClock(secondsLeft(snapshot, now)))}
        </span>
        {snapshot.status.capture === 'waiting' ? (
          <span className="max-w-[16rem] truncate text-muted-foreground">{t.waitingForBrowser}</span>
        ) : null}
        <Tip label={t.stopHint}>
          <Button disabled={busy} onClick={() => void end(false)} size="sm">
            <Codicon name="debug-stop" /> {t.stop}
          </Button>
        </Tip>
      </>
    )
  }

  if (phase === 'ended' && snapshot) {
    return (
      <>
        <span className="text-muted-foreground">
          {snapshot.status.ended === 'limit' ? t.endedLimit : t.endedReturned}
        </span>
        <Button disabled={busy} onClick={() => void end(false)} size="sm">
          <Codicon name="mortar-board" /> {t.createSkill}
        </Button>
        <Button disabled={busy} onClick={() => void end(true)} size="sm" variant="ghost">
          {t.discardRecording}
        </Button>
      </>
    )
  }

  return null
}

export function TeachSkillBanner({ bot, live }: { bot: RosterRow; live: boolean }) {
  const t = useTeach()
  const name = useBotName(bot)
  const snapshot = teachStateFor(useValue($teachState), bot)?.snapshot ?? null
  const phase = teachPhase(snapshot, live)
  const pending = pendingOf(snapshot)
  const now = useNow(phase === 'drafting')
  const [reviewing, setReviewing] = useState(false)
  const [discarding, setDiscarding] = useState(false)
  const [busy, setBusy] = useState(false)

  const refresh = useCallback(
    () => fetchTeachStatus(bot).then(next => setTeachStatus(bot, next)).catch(() => undefined),
    [bot]
  )

  const ask = useCallback(async () => {
    if (!pending) {
      return
    }

    setBusy(true)

    try {
      await askAgain(bot, pending.teach_id)
      host.notify({ kind: 'info', message: t.draft.asked(name) })
    } catch (error) {
      if (teachErrorCode(error) !== 'recording_deleted') {
        host.notify({ kind: 'error', message: t.sendFailed(name) })
      }

      await refresh()
    } finally {
      setBusy(false)
    }
  }, [bot, name, pending, refresh, t])

  const discard = useCallback(async () => {
    if (!pending) {
      return
    }

    await discardDraft(bot, pending.teach_id)
    host.notify({ kind: 'info', message: t.draft.discarded })
    await refresh()
  }, [bot, pending, refresh, t])

  if ((phase !== 'drafting' && phase !== 'ready') || !pending) {
    return null
  }

  return (
    <div
      className="flex items-center gap-2 border-b px-3 py-1.5 text-xs"
      data-slot="teach-draft-banner"
      data-teach-phase={phase}
    >
      <Codicon name={phase === 'ready' ? 'lightbulb' : 'sparkle'} />
      <span className="font-medium">{phase === 'ready' ? t.draft.ready(name) : t.draft.writing(name)}</span>
      {phase === 'drafting' ? <span className="truncate text-muted-foreground">{t.draft.writingBody}</span> : null}
      <span className="grow" />
      {phase === 'ready' ? (
        <Button onClick={() => setReviewing(true)} size="sm">
          <Codicon name="eye" /> {t.draft.review}
        </Button>
      ) : (
        <Button disabled={busy || now < askAgainWaitsUntil(bot)} onClick={() => void ask()} size="sm" variant="secondary">
          <Codicon name="refresh" /> {t.draft.askAgain}
        </Button>
      )}
      <Button disabled={busy} onClick={() => setDiscarding(true)} size="sm" variant="ghost">
        {t.draft.discard}
      </Button>
      <TeachConfirmDiscard onClose={() => setDiscarding(false)} onConfirm={discard} open={discarding} />
      <TeachReviewDialog
        bot={bot}
        name={name}
        onClose={() => setReviewing(false)}
        onSettled={refresh}
        open={reviewing}
        pending={pending}
      />
    </div>
  )
}
