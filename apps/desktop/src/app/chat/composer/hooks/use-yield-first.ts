import { useStoresSelector } from '@/lib/use-session-slice'
import { serverOwnsComposerQueue } from '@/store/composer-queue'
import { $connectionWires } from '@/store/connection-wire'
import { $connection } from '@/store/session'
import { $botChatSessionIds, $sessionStates, $sessionTiles, isBotChatSession } from '@/store/session-states'

interface UseYieldFirstArgs {
  haltRun: () => unknown
  queueScopeKey: null | string
  sessionId?: null | string
}

// A bot chat is a companion conversation, not a working session, so it has no
// repo to speak of — see the blank repoPath handed to CodingStatusRow.
// Three stores: the scope set records the answer, and resolving this runtime
// id to the stored one it is filed under reads the other two.
export function useYieldFirst({ haltRun, queueScopeKey, sessionId }: UseYieldFirstArgs) {
  const botChat = useStoresSelector([$botChatSessionIds, $sessionStates, $sessionTiles], () =>
    isBotChatSession(sessionId)
  )

  const canonicalOwner = useStoresSelector([$connection, $connectionWires, $sessionStates], () =>
    serverOwnsComposerQueue(sessionId ?? queueScopeKey)
  )

  const yieldFirst = botChat && canonicalOwner

  return { botChat, onStop: yieldFirst ? () => void Promise.resolve(haltRun()) : undefined, yieldFirst }
}
