import { act, cleanup, fireEvent, render, renderHook, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { useVoiceCallSync } from '@/app/chat/composer/hooks/use-voice-call-sync'
import { $chatPersonas, type ChatPersona, type ChatVoiceLabels } from '@/store/chat-persona'
import { $voiceConversationStartRequest } from '@/store/composer'
import { $messages, $selectedStoredSessionId, setMessages } from '@/store/session'
import { $voiceCall, acknowledgeVoiceCall, endVoiceCall, voiceCallCardLabel } from '@/store/voice-call'

import { VoiceCallControls } from './voice-call-controls'

const labels: ChatVoiceLabels = {
  callEnded: duration => `Voice chat · ${duration}`,
  callLive: 'On a call',
  hangUp: 'Hang up',
  hideTranscript: 'Hide transcript',
  listening: 'Listening',
  mute: 'Mute',
  muted: 'Muted',
  pauseMemo: 'Pause',
  playMemo: 'Play',
  showTranscript: 'Show transcript',
  speaking: 'Speaking',
  startCall: 'Start voice chat',
  thinking: 'Thinking',
  transcriptEmpty: 'Nothing said yet.',
  unmute: 'Unmute',
  you: 'You'
}

const persona = (voice?: () => ChatVoiceLabels): ChatPersona => ({ avatar: () => null, name: 'Ada', voice })

const sync = (overrides: Partial<Parameters<typeof useVoiceCallSync>[0]> = {}) => ({
  active: false,
  enabled: true,
  end: vi.fn(),
  muted: false,
  status: 'idle',
  toggleMute: vi.fn(),
  ...overrides
})

const cardLabels = () =>
  $messages
    .get()
    .map(message => message.parts[0])
    .map(part => (part?.type === 'text' ? voiceCallCardLabel(part.text) : null))
    .filter(Boolean)

describe('voice call button', () => {
  beforeEach(() => {
    endVoiceCall()
    acknowledgeVoiceCall()
    setMessages([])
    $chatPersonas.set({})
    $selectedStoredSessionId.set(null)
  })

  afterEach(cleanup)

  it('idle shows Start voice chat and asks the composer to start', () => {
    render(<VoiceCallControls labels={labels} />)

    const before = $voiceConversationStartRequest.get()

    fireEvent.click(screen.getByRole('button', { name: 'Start voice chat' }))

    expect($voiceConversationStartRequest.get()).toBe(before + 1)
    expect(screen.queryByRole('button', { name: 'Hang up' })).toBeNull()
  })

  it('live shows mute, transcript and hang up wired to the composer, then returns to start', () => {
    const calls = { end: vi.fn(), toggleMute: vi.fn() }

    const live = renderHook(({ active }) => useVoiceCallSync(sync({ ...calls, active })), {
      initialProps: { active: true }
    })

    render(<VoiceCallControls labels={labels} />)

    expect($voiceCall.get().phase).toBe('live')
    expect(screen.queryByRole('button', { name: 'Start voice chat' })).toBeNull()

    fireEvent.click(screen.getByRole('button', { name: 'Mute' }))
    expect(calls.toggleMute).toHaveBeenCalledTimes(1)

    fireEvent.click(screen.getByRole('button', { name: 'Hang up' }))
    expect(calls.end).toHaveBeenCalledTimes(1)

    expect(screen.getByRole('button', { name: 'Show transcript' })).toBeTruthy()

    act(() => live.rerender({ active: false }))

    expect($voiceCall.get().phase).toBe('idle')
    expect(screen.getByRole('button', { name: 'Start voice chat' })).toBeTruthy()
  })

  it('reflects mute and status from the engine', () => {
    const { rerender } = renderHook(props => useVoiceCallSync(sync(props)), {
      initialProps: { active: true, muted: false, status: 'listening' }
    })

    render(<VoiceCallControls labels={labels} />)
    expect(screen.getByText('Listening')).toBeTruthy()

    act(() => rerender({ active: true, muted: true, status: 'listening' }))
    expect(screen.getByText('Muted')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Unmute' }).getAttribute('aria-pressed')).toBe('true')
  })

  it('shows the call transcript in a popover', () => {
    renderHook(() => useVoiceCallSync(sync({ active: true })))
    render(<VoiceCallControls labels={labels} />)

    fireEvent.click(screen.getByRole('button', { name: 'Show transcript' }))

    expect(screen.getByText('Nothing said yet.')).toBeTruthy()
  })
})

describe('call ended card', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    endVoiceCall()
    acknowledgeVoiceCall()
    setMessages([])
    $selectedStoredSessionId.set('bot-chat')
    $chatPersonas.set({ 'bot-chat': persona(() => labels) })
  })

  afterEach(() => {
    vi.useRealTimers()
    cleanup()
  })

  it('appends "Voice chat · m:ss" to a bot chat when the call ends', () => {
    const { rerender } = renderHook(({ active }) => useVoiceCallSync(sync({ active })), {
      initialProps: { active: true }
    })

    act(() => void vi.advanceTimersByTime(125_000))
    act(() => rerender({ active: false }))

    expect(cardLabels()).toEqual(['Voice chat · 2:05'])
    expect($voiceCall.get().phase).toBe('idle')
  })

  it('skips the card for a call that never really started', () => {
    const { rerender } = renderHook(({ active }) => useVoiceCallSync(sync({ active })), {
      initialProps: { active: true }
    })

    act(() => void vi.advanceTimersByTime(300))
    act(() => rerender({ active: false }))

    expect(cardLabels()).toEqual([])
  })

  it('leaves a chat without voice labels alone', () => {
    $chatPersonas.set({ 'bot-chat': persona() })

    const { rerender } = renderHook(({ active }) => useVoiceCallSync(sync({ active })), {
      initialProps: { active: true }
    })

    act(() => void vi.advanceTimersByTime(5_000))
    act(() => rerender({ active: false }))

    expect(cardLabels()).toEqual([])
  })

  it('does not drop the card into a different chat the user switched to', () => {
    const { rerender } = renderHook(({ active }) => useVoiceCallSync(sync({ active })), {
      initialProps: { active: true }
    })

    act(() => void vi.advanceTimersByTime(5_000))
    act(() => $selectedStoredSessionId.set('other-chat'))
    act(() => rerender({ active: false }))

    expect(cardLabels()).toEqual([])
  })

  it('ignores a composer that is not the main one', () => {
    renderHook(() => useVoiceCallSync(sync({ active: true, enabled: false })))

    expect($voiceCall.get().phase).toBe('idle')
  })
})
