import type { BotTeachStatus } from '@hermes/plugin-sdk'
import { expect, it } from 'vitest'

import { formatClock, pendingOf, pollDelay, secondsLeft, snapshotOf, teachErrorCode, teachPhase } from './teach-skill-model'

const status = (patch: Partial<BotTeachStatus> = {}): BotTeachStatus => ({
  available: true,
  capture: 'idle',
  event_count: 0,
  max_seconds: 600,
  now: 1000,
  recording: false,
  truncated: false,
  ...patch
})

const phase = (patch: Partial<BotTeachStatus>, live = true) => teachPhase(snapshotOf(status(patch), 0), live)

it('is hidden until the pane is live and the backend says the bot can be taught', () => {
  expect(teachPhase(null, true)).toBe('hidden')
  expect(phase({}, false)).toBe('hidden')
  expect(phase({ available: false, reason: 'sandbox' })).toBe('hidden')
  expect(phase({})).toBe('idle')
})

it('derives the phase from the backend status alone', () => {
  expect(phase({ recording: true })).toBe('recording')
  expect(phase({ ended: 'limit' })).toBe('ended')
  expect(phase({ pending: { event_count: 3, skill_name: 'taught-x', state: 'drafting', teach_id: 't', truncated: false } })).toBe('drafting')
  expect(phase({ pending: { event_count: 3, skill_name: 'taught-x', state: 'ready', teach_id: 't', truncated: false } })).toBe('ready')
})

it('an unresolved draft stays visible even when the screen can no longer be taught', () => {
  const pending = { event_count: 3, skill_name: 'taught-x', state: 'ready', teach_id: 't', truncated: false }

  expect(phase({ available: false, pending })).toBe('ready')
  expect(pendingOf(snapshotOf(status({ pending }), 0))?.teach_id).toBe('t')
})

it('counts the time left on the gateway clock, whatever the local clock says', () => {
  const snapshot = snapshotOf(status({ deadline_at: 1600, now: 1000 }), 5_000_000)

  expect(secondsLeft(snapshot, 5_000_000)).toBe(600)
  expect(secondsLeft(snapshot, 5_000_000 + 90_000)).toBe(510)
  expect(secondsLeft(snapshot, 5_000_000 + 700_000)).toBe(0)
  expect(secondsLeft(snapshotOf(status(), 0), 0)).toBe(0)
})

it('formats the clock as m:ss', () => {
  expect(formatClock(600)).toBe('10:00')
  expect(formatClock(65)).toBe('1:05')
  expect(formatClock(-4)).toBe('0:00')
})

it('polls only while something is moving', () => {
  expect(pollDelay(null)).toBeNull()
  expect(pollDelay(status())).toBeNull()
  expect(pollDelay(status({ recording: true }))).toBeLessThanOrEqual(2000)
  expect(pollDelay(status({ ended: 'limit' }))).not.toBeNull()
  const pending = { event_count: 1, skill_name: 'taught-x', teach_id: 't', truncated: false }
  expect(pollDelay(status({ pending: { ...pending, state: 'drafting' } }))).not.toBeNull()
  expect(pollDelay(status({ pending: { ...pending, state: 'ready' } }))).toBeNull()
})

it('reads the gateway refusal code and nothing else', () => {
  expect(teachErrorCode({ data: { code: 'draft_pending' } })).toBe('draft_pending')
  expect(teachErrorCode(new Error('x'))).toBe('')
  expect(teachErrorCode(null)).toBe('')
  expect(teachErrorCode({ data: { code: 5 } })).toBe('')
})
