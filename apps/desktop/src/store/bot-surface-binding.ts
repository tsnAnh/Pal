import { computed } from 'nanostores'

import { $workspaceIsPage } from '@/app/routes'
import { allPaneIds } from '@/components/pane-shell/tree/model'
import {
  $dismissedPanes,
  $hiddenStripTabs,
  $hiddenTreePanes,
  $layoutTree,
  isPaneVisible
} from '@/components/pane-shell/tree/store'

import { $botChromeless, $botsOnly, $botStatusbarShown } from './bot-surface'
import { $chatPersonas, type ChatPersona } from './chat-persona'
import { $selectedStoredSessionId } from './session'
import { isChatPane, TILE_PANE_PREFIX } from './session-focus'
import { bindWindowChromeLayout } from './window-chrome-layout'

const SESSIONS_PANE = 'sessions'
const WORKSPACE_PANE = 'workspace'

interface BotChromeInput {
  botsOnly: boolean
  chatPaneIds: readonly string[]
  personas: Readonly<Record<string, ChatPersona>>
  selectedStoredSessionId: null | string
  workspaceIsPage: boolean
}

function sessionOfChatPane(paneId: string, selectedStoredSessionId: null | string): null | string {
  return paneId === WORKSPACE_PANE ? selectedStoredSessionId : paneId.slice(TILE_PANE_PREFIX.length)
}

export function isBotChromeless({
  botsOnly,
  chatPaneIds,
  personas,
  selectedStoredSessionId,
  workspaceIsPage
}: BotChromeInput): boolean {
  if (workspaceIsPage) {
    return false
  }

  if (botsOnly) {
    return true
  }

  return (
    chatPaneIds.length > 0 &&
    chatPaneIds.every(paneId => {
      const sessionId = sessionOfChatPane(paneId, selectedStoredSessionId)

      return sessionId !== null && Boolean(personas[sessionId])
    })
  )
}

let unbind: (() => void) | null = null

export function bindBotSurface(): void {
  unbind?.()

  const $botsOnlyDerived = computed($hiddenStripTabs, hidden => hidden.has(SESSIONS_PANE))

  const $chatPaneIds = computed([$layoutTree, $dismissedPanes, $hiddenTreePanes], tree =>
    tree ? allPaneIds(tree).filter(paneId => isChatPane(paneId) && isPaneVisible(paneId)) : []
  )

  const $chromelessDerived = computed(
    [$botsOnlyDerived, $chatPaneIds, $chatPersonas, $selectedStoredSessionId, $workspaceIsPage],
    (botsOnly, chatPaneIds, personas, selectedStoredSessionId, workspaceIsPage) =>
      isBotChromeless({ botsOnly, chatPaneIds, personas, selectedStoredSessionId, workspaceIsPage })
  )

  const stops = [
    $botsOnlyDerived.subscribe(botsOnly => $botsOnly.set(botsOnly)),
    $chromelessDerived.subscribe(chromeless => {
      $botChromeless.set(chromeless)

      if (!chromeless) {
        $botStatusbarShown.set(false)
      }
    }),
    bindWindowChromeLayout()
  ]

  unbind = () => {
    for (const stop of stops) {
      stop()
    }
  }
}
