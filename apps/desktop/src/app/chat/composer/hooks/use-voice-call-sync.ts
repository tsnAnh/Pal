import { useStore } from '@nanostores/react'
import { useEffect, useRef } from 'react'

import { useChatPersona } from '@/store/chat-persona'
import { $selectedStoredSessionId, setMessages } from '@/store/session'
import {
  acknowledgeVoiceCall,
  endVoiceCall,
  formatCallDuration,
  MIN_CALL_CARD_MS,
  registerVoiceCallControls,
  setVoiceCallMuted,
  setVoiceCallStatus,
  startVoiceCall,
  voiceCallCardMessage
} from '@/store/voice-call'

interface VoiceCallSyncArgs {
  active: boolean
  enabled: boolean
  end: () => void
  muted: boolean
  status: string
  toggleMute: () => void
}

/**
 * Publishes the main composer's live voice conversation as a call: the header's
 * call controls read it from the store, and when it ends a bot chat gets its
 * "Voice chat · m:ss" card in the transcript. The engine stays the composer's;
 * this only mirrors it.
 */
export function useVoiceCallSync({ active, enabled, end, muted, status, toggleMute }: VoiceCallSyncArgs) {
  const persona = useChatPersona(useStore($selectedStoredSessionId))
  const cardLabelRef = useRef<((duration: string) => string) | null>(null)
  const controlsRef = useRef({ end, toggleMute })

  cardLabelRef.current = persona?.voice?.().callEnded ?? null
  controlsRef.current = { end, toggleMute }

  useEffect(() => {
    if (!enabled || !active) {
      return
    }

    startVoiceCall()

    const startedIn = $selectedStoredSessionId.get()

    const disposeControls = registerVoiceCallControls({
      hangUp: () => controlsRef.current.end(),
      toggleMute: () => controlsRef.current.toggleMute()
    })

    return () => {
      disposeControls()

      const durationMs = endVoiceCall()
      const cardLabel = cardLabelRef.current

      if (
        durationMs !== null &&
        durationMs >= MIN_CALL_CARD_MS &&
        cardLabel &&
        $selectedStoredSessionId.get() === startedIn
      ) {
        setMessages(messages => [...messages, voiceCallCardMessage(cardLabel(formatCallDuration(durationMs)))])
      }

      acknowledgeVoiceCall()
    }
  }, [active, enabled])

  useEffect(() => {
    if (enabled && active) {
      setVoiceCallMuted(muted)
      setVoiceCallStatus(status)
    }
  }, [active, enabled, muted, status])
}
