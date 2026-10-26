import { useStore } from '@nanostores/react'

import { findGroupOfPane } from '@/components/pane-shell/tree/model'
import { paneChrome } from '@/components/pane-shell/tree/renderer/track-model'
import {
  $hiddenTreePanes,
  $layoutTree,
  revealTreePane,
  shownPanesInGroup,
  tabStripVisibleForGroup
} from '@/components/pane-shell/tree/store'
import { Button } from '@/components/ui/button'
import { Tip } from '@/components/ui/tooltip'
import { useContributions } from '@/contrib/react/use-contributions'
import { useI18n } from '@/i18n'
import { cn } from '@/lib/utils'
import { $tabStripDefault } from '@/store/tabstrip-prefs'

import { titlebarButtonClass } from './titlebar'
import { TitlebarIcon } from './titlebar-icon'

const SIDEBAR_ANCHOR_PANE = 'sessions'

export interface SidebarPaneEntry {
  active: boolean
  icon: string
  id: string
  label: string
}

export function useSidebarPaneEntries(): SidebarPaneEntry[] {
  const tree = useStore($layoutTree)
  const panes = useContributions('panes')
  useStore($hiddenTreePanes)
  useStore($tabStripDefault)

  const group = tree ? findGroupOfPane(tree, SIDEBAR_ANCHOR_PANE) : null

  if (!group || tabStripVisibleForGroup(group)) {
    return []
  }

  const shown = shownPanesInGroup(group)

  if (shown.length < 2) {
    return []
  }

  return shown.map(id => {
    const contribution = panes.find(c => c.id === id)
    const chrome = paneChrome(contribution)

    return {
      active: group.active === id,
      icon: chrome.switcherIcon ?? 'window',
      id,
      label: chrome.tabTitleText?.() ?? contribution?.title ?? id
    }
  })
}

export function SidebarPaneSwitcher() {
  const { t } = useI18n()
  const entries = useSidebarPaneEntries()

  if (entries.length === 0) {
    return null
  }

  return (
    <div
      aria-label={t.sidebar.paneSwitcherAria}
      className="flex flex-row items-center [-webkit-app-region:no-drag]"
      role="group"
    >
      {entries.map(({ active, icon, id, label }) => (
        <Tip key={id} label={label} placement="toolbar">
          <Button
            aria-label={label}
            aria-pressed={active}
            className={cn(
              titlebarButtonClass,
              'rounded-full select-none',
              active ? 'bg-(--ui-control-hover-background) text-foreground' : 'bg-transparent'
            )}
            onClick={() => revealTreePane(id)}
            onPointerDown={event => event.stopPropagation()}
            size="icon-titlebar"
            type="button"
            variant="ghost"
          >
            <TitlebarIcon name={icon} />
          </Button>
        </Tip>
      ))}
    </div>
  )
}
