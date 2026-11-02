import { useStore } from '@nanostores/react'
import { type RefObject, useEffect } from 'react'

import { $connectionsRegistry } from '@/store/connection-registry-state'
import { $lastConversation } from '@/store/last-conversation'
import {
  browserRestorePorts,
  claimsBootRestore,
  registryConnectionIds,
  restoreLastConversation
} from '@/store/last-conversation-restore'
import { $selectedStoredSessionId, forgetSessionOwnerHintsForUnknownConnections } from '@/store/session'
import { isBrowserWindow, isHudWindow, isPeerInstanceWindow } from '@/store/windows'

import { NEW_CHAT_ROUTE, routePathname } from '../../routes'

function bootStillPristine(): boolean {
  const path = window.location.hash.replace(/^#/, '') || NEW_CHAT_ROUTE

  return routePathname(path) === NEW_CHAT_ROUTE && !$selectedStoredSessionId.get()
}

interface RestoreLastConversationParams {
  locationPathname: string
  profileReady: boolean
  restoredRef: RefObject<boolean>
  resumeLastSession: boolean | undefined
}

export function useRestoreLastConversation({
  locationPathname,
  profileReady,
  restoredRef,
  resumeLastSession
}: RestoreLastConversationParams): void {
  const registry = useStore($connectionsRegistry)

  useEffect(() => {
    const ids = registryConnectionIds()

    if (ids) {
      forgetSessionOwnerHintsForUnknownConnections(ids)
    }
  }, [registry])

  // eslint-disable-next-line no-restricted-syntax
  useEffect(() => {
    if (
      restoredRef.current ||
      !profileReady ||
      resumeLastSession !== true ||
      locationPathname !== NEW_CHAT_ROUTE ||
      isHudWindow() ||
      isBrowserWindow() ||
      isPeerInstanceWindow() ||
      !claimsBootRestore($lastConversation.get(), registryConnectionIds())
    ) {
      return
    }

    restoredRef.current = true
    void restoreLastConversation(browserRestorePorts(bootStillPristine)).catch(() => undefined)
  }, [locationPathname, profileReady, registry, restoredRef, resumeLastSession])
}
