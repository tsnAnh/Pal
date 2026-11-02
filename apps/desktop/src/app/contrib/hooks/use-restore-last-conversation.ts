import { useStore } from '@nanostores/react'
import { type RefObject, useEffect, useRef } from 'react'

import { $connectionsRegistry } from '@/store/connection-registry-state'
import { $lastConversation } from '@/store/last-conversation'
import { startLastConversationRecorder } from '@/store/last-conversation-recorder'
import {
  $bootRestorePhase,
  browserRestorePorts,
  claimsBootRestore,
  restoreLastConversation,
  trustedRegistryConnectionIds
} from '@/store/last-conversation-restore'
import { forgetSessionOwnerHintsForUnknownConnections } from '@/store/session'
import { $focusedStoredSessionId } from '@/store/session-focus'
import { isBrowserWindow, isHudWindow, isPeerInstanceWindow } from '@/store/windows'

import { NEW_CHAT_ROUTE, routePathname } from '../../routes'

function bootStillPristine(): boolean {
  const path = window.location.hash.replace(/^#/, '') || NEW_CHAT_ROUTE

  return routePathname(path) === NEW_CHAT_ROUTE && !$focusedStoredSessionId.get()
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
  const startedRef = useRef(false)

  useEffect(() => () => $bootRestorePhase.set('idle'), [])

  useEffect(() => startLastConversationRecorder(), [])

  useEffect(() => {
    const ids = trustedRegistryConnectionIds()

    if (ids) {
      forgetSessionOwnerHintsForUnknownConnections(ids)
    }
  }, [registry])

  // eslint-disable-next-line no-restricted-syntax
  useEffect(() => {
    if (
      startedRef.current ||
      restoredRef.current ||
      !profileReady ||
      resumeLastSession !== true ||
      locationPathname !== NEW_CHAT_ROUTE ||
      isHudWindow() ||
      isBrowserWindow() ||
      isPeerInstanceWindow() ||
      !claimsBootRestore($lastConversation.get(), trustedRegistryConnectionIds())
    ) {
      return
    }

    startedRef.current = true
    $bootRestorePhase.set('restoring')

    void restoreLastConversation(browserRestorePorts(bootStillPristine))
      .then(outcome => (outcome === 'home' || outcome === 'timed-out' ? 'released' : 'handled'))
      .catch(() => 'released' as const)
      .then(phase => {
        if ($bootRestorePhase.get() !== 'restoring') {
          return
        }

        if (phase === 'handled') {
          restoredRef.current = true
        }

        $bootRestorePhase.set(phase)
      })
  }, [locationPathname, profileReady, registry, restoredRef, resumeLastSession])
}
