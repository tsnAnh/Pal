import { atom } from 'nanostores'

import { $activeConnectionId } from './connections'
import { type ConversationScope, rememberLastConversation } from './last-conversation'
import { $bootRestorePhase } from './last-conversation-restore'
import { $activeProfile } from './profile'
import { knownSessionOwner, ownerLookupSessionRows } from './session'
import { $focusedStoredSessionId } from './session-focus'
import { isMainWindow } from './windows'

export type FocusedConversationClassifier = (storedSessionId: string) => ConversationScope | 'session' | 'unknown'

export const $focusedConversationClassifier = atom<FocusedConversationClassifier | null>(null)

export function registerFocusedConversationClassifier(classifier: FocusedConversationClassifier): () => void {
  $focusedConversationClassifier.set(classifier)

  return () => {
    if ($focusedConversationClassifier.get() === classifier) {
      $focusedConversationClassifier.set(null)
    }
  }
}

function recordingAllowed(): boolean {
  return isMainWindow() && $bootRestorePhase.get() !== 'restoring'
}

export function rememberBotChatFromMainWindow(bot: ConversationScope): void {
  if (recordingAllowed()) {
    rememberLastConversation({ connectionId: bot.connectionId, kind: 'bot-chat', profile: bot.profile })
  }
}

function sessionScope(storedSessionId: string): ConversationScope | null {
  const owner = knownSessionOwner(ownerLookupSessionRows(), storedSessionId)

  if (owner && typeof owner === 'object') {
    return { connectionId: owner.connectionId, profile: owner.profile || 'default' }
  }

  const connectionId = $activeConnectionId.get()

  return connectionId ? { connectionId, profile: owner || $activeProfile.get() || 'default' } : null
}

function recordFocusedConversation(storedSessionId: null | string): void {
  const classify = $focusedConversationClassifier.get()

  if (!storedSessionId || !classify || !recordingAllowed()) {
    return
  }

  const kind = classify(storedSessionId)

  if (kind === 'unknown') {
    return
  }

  if (kind !== 'session') {
    rememberBotChatFromMainWindow(kind)

    return
  }

  const scope = sessionScope(storedSessionId)

  if (scope) {
    rememberLastConversation({ ...scope, kind: 'session', sessionId: storedSessionId })
  }
}

export function startLastConversationRecorder(): () => void {
  return $focusedStoredSessionId.listen(recordFocusedConversation)
}
