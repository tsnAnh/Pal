/**
 * The teach-a-skill flows: Teach (take control, start recording), Stop (end it, hand the bot the recording as a
 * hidden turn in its Bot Chat), and the owner's review of the draft the bot writes (load, save, approve, discard).
 * Every call is a `bot.teach.*` RPC routed like the rest of the Screen's `display.*` calls.
 */

import type {
  BotTeachDraft,
  BotTeachStatus,
  BotTeachStopResult,
  DisplayLease
} from '@hermes/plugin-sdk'

import { backendTargetProfile, botConnectionRoute, requestForBot } from './routing'
import { displayRequest, leaseHeldBy, retainBotScreen, type ScreenViewer } from './screen-connection'
import { setScreenLease } from './screen-state'
import { noteTeachSubmitted, noteTookControl, takeControlNote } from './teach-skill-state'
import type { RosterRow } from './types'

export type SubmitFailure = 'failed' | 'no_chat'

export class TeachSubmitError extends Error {
  constructor(readonly reason: SubmitFailure) {
    super(`teach prompt not delivered: ${reason}`)
  }
}

export type FinishOutcome =
  | { kind: 'empty' }
  | { kind: 'sent'; result: BotTeachStopResult }
  | { kind: 'unsent'; reason: SubmitFailure; result: BotTeachStopResult }

const teach = <T>(bot: RosterRow, method: string, params: Record<string, unknown> = {}) =>
  displayRequest<T>(bot, `bot.teach.${method}`, params)

export const fetchTeachStatus = (bot: RosterRow) => teach<BotTeachStatus>(bot, 'status')

async function releaseControl(bot: RosterRow, viewer: ScreenViewer): Promise<void> {
  const released = await displayRequest<{ lease: DisplayLease }>(bot, 'display.lease.release', { viewer_id: viewer.id })

  setScreenLease(bot, released.lease)
}

/** Take the screen when the owner does not hold it yet, then start recording for this window's viewer. A failed
 *  start gives back a screen taken only for it. */
export async function beginTeaching(
  bot: RosterRow,
  viewer: ScreenViewer,
  lease: DisplayLease | null,
  reason: string
): Promise<BotTeachStatus> {
  const took = !leaseHeldBy(lease, viewer)

  if (took) {
    const acquired = await displayRequest<{ lease: DisplayLease }>(bot, 'display.lease.acquire', {
      reason,
      viewer_id: viewer.id
    })

    setScreenLease(bot, acquired.lease)
  }

  try {
    const status = await teach<BotTeachStatus>(bot, 'start', { viewer_id: viewer.id })
    noteTookControl(bot, took)

    return status
  } catch (error) {
    if (took) {
      await releaseControl(bot, viewer).catch(() => undefined)
    }

    throw error
  }
}

/** Deliver `prompt` as a hidden turn of the bot's existing Bot Chat (the way its birth notice is delivered): the
 *  stored chat is resumed to its live runtime session, which already is the live one when the chat is open. */
export async function submitTeachPrompt(bot: RosterRow, prompt: string): Promise<void> {
  const stored = bot.canonical_session?.resolved_id || bot.canonical_session?.id

  if (!stored) {
    throw new TeachSubmitError('no_chat')
  }

  const profile = backendTargetProfile(botConnectionRoute(bot), bot.name)
  const release = await retainBotScreen(bot)

  try {
    const resumed = await requestForBot<{ session_id?: string }>(
      bot,
      'session.resume',
      { omit_messages: true, profile, session_id: stored },
      { spawnPriority: 'foreground' }
    )

    if (!resumed?.session_id) {
      throw new TeachSubmitError('failed')
    }

    await requestForBot(bot, 'prompt.submit', { display_kind: 'hidden', session_id: resumed.session_id, text: prompt })
    noteTeachSubmitted(bot)
  } catch (error) {
    throw error instanceof TeachSubmitError ? error : new TeachSubmitError('failed')
  } finally {
    release()
  }
}

/** End the recording. A recording with events becomes a disabled draft and its prompt goes to the bot; if the prompt
 *  cannot be delivered the draft still exists and `askAgain` retries it. */
export async function finishTeaching(
  bot: RosterRow,
  viewer: null | ScreenViewer,
  { discard = false }: { discard?: boolean } = {}
): Promise<FinishOutcome> {
  const result = await teach<BotTeachStopResult>(bot, 'stop', { discard })

  const tookControl = takeControlNote(bot)

  if (tookControl && viewer && result.reason !== 'control_returned') {
    await releaseControl(bot, viewer).catch(() => undefined)
  }

  if (result.empty || !result.prompt) {
    return { kind: 'empty' }
  }

  try {
    await submitTeachPrompt(bot, result.prompt)

    return { kind: 'sent', result }
  } catch (error) {
    return { kind: 'unsent', reason: error instanceof TeachSubmitError ? error.reason : 'failed', result }
  }
}

export async function askAgain(bot: RosterRow, teachId: string): Promise<void> {
  const { prompt } = await teach<{ prompt: string }>(bot, 'prompt', { teach_id: teachId })

  await submitTeachPrompt(bot, prompt)
}

export const loadDraft = (bot: RosterRow, teachId: string) => teach<BotTeachDraft>(bot, 'draft', { teach_id: teachId })

export const saveDraft = (bot: RosterRow, teachId: string, content: string) =>
  teach<BotTeachDraft>(bot, 'draft.save', { content, teach_id: teachId })

/** Approve what the owner saw: their own edit (`content`), or the version whose `content_hash` they reviewed. */
export const approveDraft = (bot: RosterRow, teachId: string, reviewed: { content: string } | { contentHash: string }) =>
  teach<Pick<BotTeachDraft, 'skill_name'>>(bot, 'approve', {
    teach_id: teachId,
    ...('content' in reviewed ? { content: reviewed.content } : { content_hash: reviewed.contentHash })
  })

export const discardDraft = (bot: RosterRow, teachId: string) =>
  teach<{ discarded: boolean }>(bot, 'discard', { teach_id: teachId })
