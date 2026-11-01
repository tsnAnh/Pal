import { atom } from 'nanostores'

import { type ChatMessage, textPart } from '@/lib/chat-messages'

export type VoiceCallPhase = 'ended' | 'idle' | 'live'

export interface VoiceCallState {
  durationMs: null | number
  muted: boolean
  phase: VoiceCallPhase
  startedAt: null | number
  status: string
}

export interface VoiceCallControls {
  hangUp: () => void
  toggleMute: () => void
}

export const MIN_CALL_CARD_MS = 1000
export const VOICE_CALL_CARD_PREFIX = 'voice-chat:'

const IDLE: VoiceCallState = { durationMs: null, muted: false, phase: 'idle', startedAt: null, status: 'idle' }

export const $voiceCall = atom<VoiceCallState>(IDLE)
export const $voiceCallControls = atom<null | VoiceCallControls>(null)

export function startVoiceCall(now = Date.now()): boolean {
  if ($voiceCall.get().phase === 'live') {
    return false
  }

  $voiceCall.set({ ...IDLE, phase: 'live', startedAt: now })

  return true
}

export function setVoiceCallMuted(muted: boolean): void {
  const call = $voiceCall.get()

  if (call.phase === 'live' && call.muted !== muted) {
    $voiceCall.set({ ...call, muted })
  }
}

export function setVoiceCallStatus(status: string): void {
  const call = $voiceCall.get()

  if (call.phase === 'live' && call.status !== status) {
    $voiceCall.set({ ...call, status })
  }
}

export function endVoiceCall(now = Date.now()): null | number {
  const call = $voiceCall.get()

  if (call.phase !== 'live' || call.startedAt === null) {
    return null
  }

  const durationMs = Math.max(0, now - call.startedAt)

  $voiceCall.set({ ...call, durationMs, muted: false, phase: 'ended', status: 'idle' })

  return durationMs
}

export function acknowledgeVoiceCall(): void {
  if ($voiceCall.get().phase === 'ended') {
    $voiceCall.set(IDLE)
  }
}

export function registerVoiceCallControls(controls: VoiceCallControls): () => void {
  $voiceCallControls.set(controls)

  return () => {
    if ($voiceCallControls.get() === controls) {
      $voiceCallControls.set(null)
    }
  }
}

export function formatCallDuration(durationMs: number): string {
  const total = Math.max(0, Math.floor(durationMs / 1000))
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const seconds = String(total % 60).padStart(2, '0')

  return hours > 0 ? `${hours}:${String(minutes).padStart(2, '0')}:${seconds}` : `${minutes}:${seconds}`
}

export function voiceCallCardMessage(label: string, now = Date.now()): ChatMessage {
  const seconds = now / 1000

  return {
    id: `voice-chat-${now}`,
    parts: [textPart(`${VOICE_CALL_CARD_PREFIX}${label}`, seconds)],
    role: 'system',
    timestamp: seconds
  }
}

export function voiceCallCardLabel(text: string): null | string {
  const label = text.startsWith(VOICE_CALL_CARD_PREFIX) ? text.slice(VOICE_CALL_CARD_PREFIX.length).trim() : ''

  return label || null
}

export function callTurns(messages: readonly ChatMessage[], startedAt: null | number): ChatMessage[] {
  if (startedAt === null) {
    return []
  }

  const since = startedAt / 1000 - 2

  return messages.filter(
    message =>
      !message.hidden && (message.role === 'user' || message.role === 'assistant') && (message.timestamp ?? 0) >= since
  )
}
