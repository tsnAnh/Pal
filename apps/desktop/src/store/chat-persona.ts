import { useStore } from '@nanostores/react'
import { atom } from 'nanostores'
import { createContext, type ReactNode, useContext } from 'react'

export interface ChatVoiceLabels {
  callEnded: (duration: string) => string
  callLive: string
  hangUp: string
  hideTranscript: string
  listening: string
  mute: string
  muted: string
  pauseMemo: string
  playMemo: string
  showTranscript: string
  speaking: string
  startCall: string
  thinking: string
  transcriptEmpty: string
  unmute: string
  you: string
}

export interface ChatPersona {
  avatar: (size: number) => ReactNode
  name: string
  stopNowLabel?: () => string
  voice?: () => ChatVoiceLabels
}

export const $chatPersonas = atom<Readonly<Record<string, ChatPersona>>>({})

function samePersonas(a: Readonly<Record<string, ChatPersona>>, b: Readonly<Record<string, ChatPersona>>): boolean {
  const keys = Object.keys(a)

  return keys.length === Object.keys(b).length && keys.every(key => a[key] === b[key])
}

export function setChatPersonas(personas: Readonly<Record<string, ChatPersona>>): void {
  if (!samePersonas($chatPersonas.get(), personas)) {
    $chatPersonas.set(personas)
  }
}

export const $handlePersonas = atom<Readonly<Record<string, ChatPersona>>>({})

export function setHandlePersonas(personas: Readonly<Record<string, ChatPersona>>): void {
  if (!samePersonas($handlePersonas.get(), personas)) {
    $handlePersonas.set(personas)
  }
}

export function useHandlePersona(handle: null | string | undefined): ChatPersona | null {
  const personas = useStore($handlePersonas)
  const key = handle?.trim().toLowerCase()

  return key && Object.hasOwn(personas, key) ? personas[key] : null
}

export function useChatPersona(storedSessionId: null | string | undefined): ChatPersona | null {
  const personas = useStore($chatPersonas)

  return (storedSessionId && personas[storedSessionId]) || null
}

export const ChatPersonaContext = createContext<ChatPersona | null>(null)

export function useSurfacePersona(): ChatPersona | null {
  return useContext(ChatPersonaContext)
}
