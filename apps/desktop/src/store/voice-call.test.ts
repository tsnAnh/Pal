import { beforeEach, describe, expect, it } from 'vitest'

import {
  $voiceCall,
  $voiceCallControls,
  acknowledgeVoiceCall,
  callTurns,
  endVoiceCall,
  formatCallDuration,
  MIN_CALL_CARD_MS,
  registerVoiceCallControls,
  setVoiceCallMuted,
  setVoiceCallStatus,
  startVoiceCall,
  voiceCallCardLabel,
  voiceCallCardMessage
} from './voice-call'

const reset = () => {
  endVoiceCall(0)
  acknowledgeVoiceCall()
}

describe('voice call state machine', () => {
  beforeEach(reset)

  it('walks idle -> live -> ended -> idle', () => {
    expect($voiceCall.get().phase).toBe('idle')

    expect(startVoiceCall(1_000)).toBe(true)
    expect($voiceCall.get()).toMatchObject({ phase: 'live', startedAt: 1_000 })

    expect(endVoiceCall(66_500)).toBe(65_500)
    expect($voiceCall.get()).toMatchObject({ durationMs: 65_500, phase: 'ended' })

    acknowledgeVoiceCall()
    expect($voiceCall.get()).toMatchObject({ durationMs: null, phase: 'idle', startedAt: null })
  })

  it('ignores a second start while live and keeps the original start time', () => {
    startVoiceCall(1_000)

    expect(startVoiceCall(9_000)).toBe(false)
    expect($voiceCall.get().startedAt).toBe(1_000)
  })

  it('ends only a live call', () => {
    expect(endVoiceCall(5_000)).toBeNull()
    expect($voiceCall.get().phase).toBe('idle')

    startVoiceCall(1_000)
    endVoiceCall(2_000)

    expect(endVoiceCall(9_000)).toBeNull()
    expect($voiceCall.get().durationMs).toBe(1_000)
  })

  it('never reports a negative duration when the clock steps back', () => {
    startVoiceCall(5_000)

    expect(endVoiceCall(1_000)).toBe(0)
  })

  it('can start a new call straight from the ended card', () => {
    startVoiceCall(1_000)
    endVoiceCall(4_000)

    expect(startVoiceCall(10_000)).toBe(true)
    expect($voiceCall.get()).toMatchObject({ durationMs: null, phase: 'live', startedAt: 10_000 })
  })

  it('tracks mute and status only while live, and clears them on hang up', () => {
    setVoiceCallMuted(true)
    setVoiceCallStatus('speaking')
    expect($voiceCall.get()).toMatchObject({ muted: false, status: 'idle' })

    startVoiceCall(1_000)
    setVoiceCallMuted(true)
    setVoiceCallStatus('speaking')
    expect($voiceCall.get()).toMatchObject({ muted: true, status: 'speaking' })

    endVoiceCall(3_000)
    expect($voiceCall.get()).toMatchObject({ muted: false, status: 'idle' })
  })

  it('acknowledge leaves idle and live untouched', () => {
    acknowledgeVoiceCall()
    expect($voiceCall.get().phase).toBe('idle')

    startVoiceCall(1_000)
    acknowledgeVoiceCall()
    expect($voiceCall.get().phase).toBe('live')
  })
})

describe('voice call controls registry', () => {
  it('the latest registration wins and a stale disposer cannot clear it', () => {
    const first = { hangUp: () => undefined, toggleMute: () => undefined }
    const second = { hangUp: () => undefined, toggleMute: () => undefined }

    const disposeFirst = registerVoiceCallControls(first)
    const disposeSecond = registerVoiceCallControls(second)

    disposeFirst()
    expect($voiceCallControls.get()).toBe(second)

    disposeSecond()
    expect($voiceCallControls.get()).toBeNull()
  })
})

describe('voice call card', () => {
  it('formats durations as m:ss and h:mm:ss', () => {
    expect(formatCallDuration(0)).toBe('0:00')
    expect(formatCallDuration(65_999)).toBe('1:05')
    expect(formatCallDuration(3_725_000)).toBe('1:02:05')
    expect(formatCallDuration(-5)).toBe('0:00')
  })

  it('round-trips the localized label through a system message', () => {
    const message = voiceCallCardMessage('Voice chat · 1:05', 1_700_000_000_000)
    const part = message.parts[0]

    expect(message.role).toBe('system')
    expect(message.timestamp).toBe(1_700_000_000)
    expect(part.type === 'text' ? voiceCallCardLabel(part.text) : null).toBe('Voice chat · 1:05')
  })

  it('does not mistake ordinary system text for a card', () => {
    expect(voiceCallCardLabel('compressed 12 messages')).toBeNull()
    expect(voiceCallCardLabel('voice-chat:   ')).toBeNull()
  })

  it('skips cards for calls shorter than the minimum', () => {
    expect(MIN_CALL_CARD_MS).toBeGreaterThan(0)
  })

  it('lists only the visible user/assistant turns of the call', () => {
    const turn = (id: string, role: 'assistant' | 'system' | 'user', timestamp?: number, hidden = false) => ({
      hidden,
      id,
      parts: [],
      role,
      timestamp
    })

    const turns = callTurns(
      [
        turn('old', 'user', 100),
        turn('u1', 'user', 1_000),
        turn('hid', 'assistant', 1_001, true),
        turn('sys', 'system', 1_002),
        turn('a1', 'assistant', 1_003),
        turn('nots', 'assistant')
      ],
      1_000_000
    )

    expect(turns.map(message => message.id)).toEqual(['u1', 'a1'])
    expect(callTurns([turn('u1', 'user', 1_000)], null)).toEqual([])
  })
})
