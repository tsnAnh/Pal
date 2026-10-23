import { useStore } from '@nanostores/react'
import { atom } from 'nanostores'
import { createContext, type ReactNode, useContext } from 'react'

export interface ChatPersona {
  avatar: (size: number) => ReactNode
  name: string
  openProfile?: () => void
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

export function useChatPersona(storedSessionId: null | string | undefined): ChatPersona | null {
  const personas = useStore($chatPersonas)

  return (storedSessionId && personas[storedSessionId]) || null
}

export const ChatPersonaContext = createContext<ChatPersona | null>(null)

export function useSurfacePersona(): ChatPersona | null {
  return useContext(ChatPersonaContext)
}
