import { describe, expect, it } from 'vitest'

import { type BusySubmitInputs, deriveBusySubmitState } from './busy-submit-state'

const busyTyping: BusySubmitInputs = {
  attachmentCount: 0,
  blockingPrompt: false,
  busy: true,
  busyInputMode: 'interrupt',
  compacting: false,
  hasComposerPayload: true,
  hasSteerHandler: true,
  isSteerableText: true,
  yieldFirst: false
}

describe('deriveBusySubmitState', () => {
  it('keeps a non-yield chat on the backend busy-input policy', () => {
    expect(deriveBusySubmitState(busyTyping)).toEqual({ busyAction: 'interrupt', canSteer: true, canSubmit: true })
    expect(deriveBusySubmitState({ ...busyTyping, busyInputMode: 'queue' }).busyAction).toBe('queue')
    expect(deriveBusySubmitState({ ...busyTyping, attachmentCount: 1 }).busyAction).toBe('queue')
    expect(deriveBusySubmitState({ ...busyTyping, hasComposerPayload: false, isSteerableText: false }).busyAction).toBe(
      'stop'
    )
  })

  it.each([
    ['interrupt', 'interrupt'],
    ['steer', 'steer'],
    ['queue', 'queue'],
    ['unloaded policy', null]
  ] as const)('a yield-first chat sends while busy whatever the busy-input policy is (%s)', (_, busyInputMode) => {
    expect(deriveBusySubmitState({ ...busyTyping, busyInputMode, yieldFirst: true })).toEqual({
      busyAction: 'send',
      canSteer: false,
      canSubmit: true
    })
  })

  it('a yield-first chat still sends with attachments, during compaction and behind a blocking prompt', () => {
    for (const patch of [{ attachmentCount: 2 }, { compacting: true }, { blockingPrompt: true }]) {
      expect(deriveBusySubmitState({ ...busyTyping, ...patch, yieldFirst: true }).busyAction).toBe('send')
    }
  })

  it('a yield-first chat shows Stop on an empty composer and stays submittable only while busy', () => {
    expect(deriveBusySubmitState({ ...busyTyping, hasComposerPayload: false, yieldFirst: true })).toEqual({
      busyAction: 'stop',
      canSteer: false,
      canSubmit: true
    })
    expect(
      deriveBusySubmitState({ ...busyTyping, busy: false, hasComposerPayload: false, yieldFirst: true }).canSubmit
    ).toBe(false)
  })
})
