import { $bootRestorePhase } from '@/store/last-conversation-restore'
import {
  sessionBelongsToProfile,
  sessionMatchesStoredId,
  setRememberedRoute,
  setRememberedSessionId
} from '@/store/session'
import type { SessionInfo } from '@/types/hermes'

import { appViewForPath, isOverlayView, NEW_CHAT_ROUTE, sessionRoute } from '../../routes'

interface PersistRememberedNavigationParams {
  activeProfile: string
  locationPathname: string
  resumeExhaustedSessionId: null | string
  routedSessionId: null | string
  sessions: readonly Pick<SessionInfo, '_lineage_root_id' | 'id' | 'parent_session_id' | 'profile' | 'source'>[]
}

export function persistRememberedNavigation({
  activeProfile,
  locationPathname,
  resumeExhaustedSessionId,
  routedSessionId,
  sessions
}: PersistRememberedNavigationParams): void {
  // Remember the open chat (session id for notifications/resume) AND the last
  // non-overlay route (a page like /skills, or a session route) per profile.
  // Session-shaped routes require an explicit matching owner; unresolved and
  // wrong-profile rows must not replace known-safe navigation.
  // The resume-exhausted session must not be written back into remembered
  // navigation: the cleanup effect above drops it once, but this
  // persistence effect re-runs on every session-list refresh while its
  // deps are unchanged — without the barrier the dead id outlives every
  // restart and the window boots into the resume-error screen each time.
  const exhausted = routedSessionId !== null && routedSessionId === resumeExhaustedSessionId

  if (routedSessionId && !exhausted && sessionBelongsToProfile(sessions, routedSessionId, activeProfile)) {
    // A delegate child (source='subagent') is never itself a rememberable
    // destination: it is invisible in the sidebar, so a restart would resume
    // an orphan chat while the sidebar highlights its parent (#56983).
    // `/branch` children also carry parent_session_id but ARE user-facing —
    // source, not parenthood, is the discriminator.
    const routedRow = sessions.find(session => sessionMatchesStoredId(session, routedSessionId))

    const rememberedSessionId = routedRow?.source === 'subagent' ? routedRow.parent_session_id || null : routedSessionId

    if (rememberedSessionId) {
      setRememberedSessionId(rememberedSessionId, activeProfile)
      setRememberedRoute(
        rememberedSessionId === routedSessionId ? locationPathname : sessionRoute(rememberedSessionId),
        activeProfile
      )
    }
  } else if (
    !routedSessionId &&
    !isOverlayView(appViewForPath(locationPathname)) &&
    !($bootRestorePhase.get() === 'handled' && locationPathname === NEW_CHAT_ROUTE)
  ) {
    setRememberedRoute(locationPathname, activeProfile)
  }
}
