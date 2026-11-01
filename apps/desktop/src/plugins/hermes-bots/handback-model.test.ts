import { expect, it } from 'vitest'

import { handbackPhase, parseHandbackAsk } from './handback-model'
import type { DisplayLease } from './screen-connection'

const ask = { reason: 'Sign in to Example to continue', requestedAt: 7.5 }

const lease = (patch: Partial<DisplayLease> = {}): DisplayLease => ({
  ask: ask.reason,
  ask_at: ask.requestedAt,
  epoch: 1,
  holder: 'agent',
  since: 1,
  viewer_hash: null,
  ...patch
})

it('reads the reason and generation from an accepted call, as an object or JSON text', () => {
  const body = { reason: 'Sign in to Example to continue', requested_at: 7.5, success: true }
  expect(parseHandbackAsk({}, body)).toEqual(ask)
  expect(parseHandbackAsk({}, JSON.stringify(body))).toEqual(ask)
  expect(parseHandbackAsk({ reason: 'From args' }, { requested_at: 1, success: true })).toEqual({
    reason: 'From args',
    requestedAt: 1
  })
})

it('draws no card for a refused call, a missing generation or a blank reason', () => {
  expect(parseHandbackAsk({}, { error: 'reason is required' })).toBeNull()
  expect(parseHandbackAsk({ reason: 'x' }, { success: true })).toBeNull()
  expect(parseHandbackAsk({}, { requested_at: 1, success: true })).toBeNull()
  expect(parseHandbackAsk({}, 'not json')).toBeNull()
})

it('derives the card state from the lease alone', () => {
  const viewer = { hash: 'abc', id: 'v' }
  expect(handbackPhase(ask, null, null, false)).toBe('checking')
  expect(handbackPhase(ask, lease(), null, true)).toBe('unavailable')
  expect(handbackPhase(ask, lease(), null, false)).toBe('pending')
  expect(handbackPhase(ask, lease({ holder: 'human', viewer_hash: 'abc' }), viewer, false)).toBe('inControl')
  expect(handbackPhase(ask, lease({ holder: 'human', viewer_hash: 'zzz' }), viewer, false)).toBe('elsewhere')
})

it('settles once the lease carries no ask or a newer one', () => {
  expect(handbackPhase(ask, lease({ ask: '', ask_at: 0 }), null, false)).toBe('resolved')
  expect(handbackPhase(ask, lease({ ask_at: 9 }), null, false)).toBe('resolved')
  expect(handbackPhase(ask, lease({ ask: undefined, ask_at: undefined }), null, false)).toBe('resolved')
})
