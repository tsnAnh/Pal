import {
  $botChromeless,
  $hiddenStripTabs,
  Button,
  cn,
  Codicon,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
  GlyphSpinner,
  SearchField,
  setStripTabHidden,
  Tip,
  useValue
} from '@hermes/plugin-sdk'
import { type ReactNode, type RefObject, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'

import { AboutYouMenuItem } from './about-you-dialog'
import { openBotSearch } from './bot-search-state'
import { BotTemplateImportMenuItem } from './bot-template-dialog'
import { connectionName, groupSelectionElsewhere, seatableGroupBots, useGroupCapability } from './canonical-group-capabilities'
import { $canonicalGroupLink, retryCanonicalGroups } from './canonical-group-registry'
import { ConnectAppsMenuItem } from './connect-apps-dialog'
import { botSourceStatus } from './data'
import type { useBots } from './i18n'
import { setActivityToasts } from './roster-actions'
import { GatewayKindGlyph } from './roster-sections'
import type { rosterGatewayOptions } from './roster-sections'
import type { RosterActivityFilter, RosterKindFilter, RosterRow } from './types'

export const SESSIONS_PANE = 'sessions'

function TitlebarLift({ children, lifted }: { children: ReactNode; lifted: boolean }) {
  const anchorRef = useRef<HTMLDivElement>(null)
  const chromeless = useValue($botChromeless)
  const [header, setHeader] = useState<HTMLElement | null>(null)

  useLayoutEffect(() => {
    const zone = lifted && !chromeless ? anchorRef.current?.closest('[data-tree-group]') : null

    setHeader(zone?.querySelector<HTMLElement>(':scope > [data-panel-header]') ?? null)
  }, [lifted, chromeless])

  if (lifted && header) {
    return createPortal(
      <div className="absolute top-px right-[19px] z-10 flex items-center [-webkit-app-region:no-drag]">
        {children}
      </div>,
      header
    )
  }

  if (chromeless) {
    return (
      <div
        className="flex h-[52px] shrink-0 items-center justify-end px-4 [-webkit-app-region:drag]"
        data-slot="bots-roster-toolbar"
        ref={anchorRef}
      >
        <div className="[-webkit-app-region:no-drag]">{children}</div>
      </div>
    )
  }

  return (
    <div className="flex items-center justify-end px-[19px] pt-[15px] pb-3" ref={anchorRef}>
      {children}
    </div>
  )
}

export function GatewayRetryButton({ b }: { b: ReturnType<typeof useBots> }) {
  const link = useValue($canonicalGroupLink)

  if (link === 'ok') {
    return null
  }

  return (
    <Tip label={b.canonical.retry}>
      <Button
        aria-label={b.canonical.retry}
        className="grid size-8 place-items-center rounded-full bg-(--bot-control-fill,var(--chrome-action-hover)) p-0 text-(--ui-text-secondary) hover:text-foreground"
        disabled={link === 'retrying'}
        onClick={retryCanonicalGroups}
        size="icon-xs"
        variant="ghost"
      >
        {link === 'retrying' ? (
          <GlyphSpinner spinner="breathe" />
        ) : (
          <Codicon className="block leading-none" name="refresh" />
        )}
      </Button>
    </Tip>
  )
}

export function GatewayUnreachableNotice({ b }: { b: ReturnType<typeof useBots> }) {
  const link = useValue($canonicalGroupLink)

  if (link === 'ok') {
    return null
  }

  return (
    <div
      className="flex flex-col items-center gap-1 px-6 pt-8 pb-4 text-center text-(--ui-text-tertiary)"
      data-slot="bots-gateway-unreachable"
    >
      <Codicon name="debug-disconnect" size="1.25rem" />
      <p className="text-sm font-medium text-(--ui-text-secondary)">{b.canonical.unreachableTitle}</p>
      <p className="text-xs leading-relaxed">{b.canonical.unreachableDesc}</p>
    </div>
  )
}

function BotsOnlyModeItem({ enterLabel, exitLabel }: { enterLabel: string; exitLabel: string }) {
  const botsOnly = useValue($hiddenStripTabs).has(SESSIONS_PANE)

  return (
    <DropdownMenuItem onSelect={() => setStripTabHidden(SESSIONS_PANE, !botsOnly)}>
      <Codicon className="mr-1.5" name={botsOnly ? 'list-unordered' : 'hubot'} />
      {botsOnly ? exitLabel : enterLabel}
    </DropdownMenuItem>
  )
}

interface NewGroupChatItemProps {
  label: string
  /** The dialog's "these bots all live on <connection>" note. */
  elsewhereNote: (connection: string) => string
  onSelect: () => void
  roster: RosterRow[]
}

/** Mounted only while the menu is open, so the capability read happens on
 *  demand. Offered only when the dialog it opens can create a room: two
 *  seatable bots by the same predicate the dialog's picker uses, and not all of
 *  them on ONE other connection (every selection there is refused, so the item
 *  says why instead of opening a dead Create button). */
function NewGroupChatItem({ elsewhereNote, label, onSelect, roster }: NewGroupChatItemProps) {
  const { connectionId, mode, seatable } = useGroupCapability(true)
  const seatableBots = seatableGroupBots(roster, { connectionId, mode, seatable })
  const elsewhere = mode === 'canonical' && groupSelectionElsewhere(seatableBots, connectionId)

  return (
    <DropdownMenuItem disabled={seatableBots.length < 2 || elsewhere} onSelect={onSelect}>
      <Codicon className="mr-1.5" name="organization" />
      {elsewhere ? (
        <span className="grid gap-0.5">
          <span>{label}</span>
          <span className="text-xs text-(--ui-text-secondary)" role="note">
            {elsewhereNote(connectionName(seatableBots[0]))}
          </span>
        </span>
      ) : (
        label
      )}
    </DropdownMenuItem>
  )
}

interface renderRosterToolbarProps {
  b: ReturnType<typeof useBots>
  botsOnly: boolean
  activityToasts: boolean
  activeSourceRoster: RosterRow[]
  /** Full roster; New Group Chat seats only `seatableGroupBots` of it. */
  roster: RosterRow[]
  setCreateOpen: (value: boolean) => void
  setGroupCreateOpen: (value: boolean) => void
  setSectionDialog: (
    value: null | { bot?: RosterRow; mode: 'create' } | { id: string; mode: 'rename'; name: string }
  ) => void
  showRosterTools: boolean
  searchInputRef: RefObject<HTMLInputElement | null>
  searchOpen: boolean
  setSearchOpen: (value: boolean) => void
  showRosterSearch: boolean
  showRosterFilters: boolean
  query: string
  setQuery: (value: string) => void
  activeFilterCount: number
  gatewayOptions: ReturnType<typeof rosterGatewayOptions>
  rowKindFilter: RosterKindFilter
  setRowKindFilter: (value: RosterKindFilter) => void
  activityFilter: RosterActivityFilter
  setActivityFilter: (value: RosterActivityFilter) => void
  gatewayFilter: string
  setGatewayFilter: (value: string) => void
}

export function renderRosterToolbar({
  botsOnly,
  b,
  activityToasts,
  activeSourceRoster,
  roster,
  setCreateOpen,
  setGroupCreateOpen,
  setSectionDialog,
  showRosterTools,
  searchInputRef,
  searchOpen,
  setSearchOpen,
  showRosterSearch,
  showRosterFilters,
  query,
  setQuery,
  activeFilterCount,
  gatewayOptions,
  rowKindFilter,
  setRowKindFilter,
  activityFilter,
  setActivityFilter,
  gatewayFilter,
  setGatewayFilter
}: renderRosterToolbarProps) {
  return (
    <>
      <TitlebarLift lifted={botsOnly}>
        <div className="flex items-center gap-2">
          {showRosterSearch ? null : (
            <Tip label={b.roster.search}>
              <Button
                aria-label={b.roster.search}
                className="grid size-8 place-items-center rounded-full bg-(--bot-control-fill,var(--chrome-action-hover)) p-0 text-(--ui-text-secondary) hover:text-foreground"
                onClick={openBotSearch}
                size="icon-xs"
                variant="ghost"
              >
                <Codicon className="block leading-none" name="search" />
              </Button>
            </Tip>
          )}
          <GatewayRetryButton b={b} />
          <DropdownMenu>
            <Tip label={b.roster.newMenu}>
              <DropdownMenuTrigger asChild>
                <Button
                  aria-label={b.roster.newBotOrGroup}
                  className="grid size-8 place-items-center rounded-full bg-(--bot-control-fill,var(--chrome-action-hover)) p-0 text-(--ui-text-secondary) hover:text-foreground"
                  size="icon-xs"
                  variant="ghost"
                >
                  <Codicon className="block leading-none" name="add" />
                </Button>
              </DropdownMenuTrigger>
            </Tip>
            <DropdownMenuContent align="end">
              <DropdownMenuItem onSelect={() => setCreateOpen(true)}>
                <Codicon className="mr-1.5" name="hubot" />
                {b.bot.newTitle}
              </DropdownMenuItem>
              <BotTemplateImportMenuItem />
              <NewGroupChatItem
                elsewhereNote={b.crossGateway.selectionElsewhere}
                label={b.group.newTitle}
                onSelect={() => setGroupCreateOpen(true)}
                roster={roster}
              />
              <DropdownMenuSeparator />
              <DropdownMenuItem onSelect={() => setSectionDialog({ mode: 'create' })}>
                <Codicon className="mr-1.5" name="new-folder" />
                {b.sections.newSection}
              </DropdownMenuItem>
              <ConnectAppsMenuItem />
              <DropdownMenuSeparator />
              <DropdownMenuItem onSelect={() => setActivityToasts(!activityToasts)}>
                <Codicon className="mr-1.5" name={activityToasts ? 'bell-slash' : 'bell'} />
                {activityToasts ? b.roster.silenceActivityToasts : b.roster.enableActivityToasts}
              </DropdownMenuItem>
              <BotsOnlyModeItem enterLabel={b.roster.botsOnlyMode} exitLabel={b.roster.showSessionsSidebar} />
              <AboutYouMenuItem />
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </TitlebarLift>
      <GatewayUnreachableNotice b={b} />
      {showRosterTools || searchOpen ? (
        <div className="flex min-w-0 items-center gap-1 px-2.5 pt-1 pb-1.5">
          {showRosterSearch || searchOpen ? (
            <SearchField
              aria-label={b.roster.search}
              containerClassName={cn('min-w-0 flex-1', query ? 'opacity-100!' : 'opacity-50 focus-within:opacity-100')}
              inputClassName="w-full text-[0.75rem] placeholder:text-(--ui-text-tertiary)"
              inputRef={searchInputRef}
              key={'roster-search'}
              onChange={setQuery}
              placeholder={b.roster.searchPlaceholder}
              value={query}
            />
          ) : (
            <span className="min-w-0 flex-1" key={'roster-search-spacer'} />
          )}
          {showRosterFilters ? (
            <DropdownMenu key={'roster-filters'}>
              <Tip label={activeFilterCount ? b.roster.filtersActive(activeFilterCount) : b.roster.filter}>
                <DropdownMenuTrigger asChild>
                  <Button
                    aria-label={activeFilterCount ? b.roster.filtersActive(activeFilterCount) : b.roster.filter}
                    className={cn(
                      'size-7 shrink-0 rounded-md text-(--ui-text-tertiary) hover:text-foreground',
                      activeFilterCount && 'text-(--ui-accent)'
                    )}
                    size="icon-xs"
                    variant="ghost"
                  >
                    <Codicon name="list-filter" />
                  </Button>
                </DropdownMenuTrigger>
              </Tip>
              <DropdownMenuContent align="end">
                {(
                  [
                    ['all', b.roster.botsAndGroups],
                    ['bots', b.roster.botsOnly],
                    ['groups', b.roster.groupsOnly]
                  ] as [RosterKindFilter, string][]
                ).map(([value, label]) => (
                  <DropdownMenuItem key={`kind:${value}`} onSelect={() => setRowKindFilter(value)}>
                    <span className="min-w-0 flex-1">{label}</span>
                    {rowKindFilter === value ? <Codicon name="check" /> : null}
                  </DropdownMenuItem>
                ))}
                <DropdownMenuSeparator />
                {(
                  [
                    ['all', b.roster.anyActivity],
                    ['active', b.roster.activeNow],
                    ['recent', b.roster.recentlyActive],
                    ['older', b.roster.older]
                  ] as [RosterActivityFilter, string][]
                ).map(([value, label]) => (
                  <DropdownMenuItem key={`activity:${value}`} onSelect={() => setActivityFilter(value)}>
                    <span className="min-w-0 flex-1">{label}</span>
                    {activityFilter === value ? <Codicon name="check" /> : null}
                  </DropdownMenuItem>
                ))}
                {gatewayOptions.length > 1 ? <DropdownMenuSeparator /> : null}
                {gatewayOptions.length > 1 ? (
                  <DropdownMenuItem onSelect={() => setGatewayFilter('all')}>
                    <Codicon className="mr-1.5" name="globe" />
                    <span className="min-w-0 flex-1">{b.roster.allGateways}</span>
                    {gatewayFilter === 'all' ? <Codicon name="check" /> : null}
                  </DropdownMenuItem>
                ) : null}
                {gatewayOptions.length > 1
                  ? gatewayOptions.map(option => {
                      const status = botSourceStatus({
                        sourceError: option.error,
                        sourceReachable: option.reachable
                      })

                      return (
                        <DropdownMenuItem
                          key={option.connectionId}
                          onSelect={() => setGatewayFilter(option.connectionId)}
                        >
                          <GatewayKindGlyph
                            className={cn('mr-1.5', !status.available && 'text-amber-600 dark:text-amber-300')}
                            kind={option.kind}
                          />
                          <span className="min-w-0 flex-1 truncate">{option.label || option.connectionId}</span>
                          <span className="text-[0.625rem] tabular-nums text-(--ui-text-quaternary)">
                            {option.count}
                          </span>
                          {gatewayFilter === option.connectionId ? <Codicon name="check" /> : null}
                        </DropdownMenuItem>
                      )
                    })
                  : []}
                {activeFilterCount ? <DropdownMenuSeparator /> : null}
                {activeFilterCount ? (
                  <DropdownMenuItem
                    onSelect={() => {
                      setRowKindFilter('all')
                      setActivityFilter('all')
                      setGatewayFilter('all')
                    }}
                  >
                    {b.roster.clearFilters}
                  </DropdownMenuItem>
                ) : null}
              </DropdownMenuContent>
            </DropdownMenu>
          ) : null}
        </div>
      ) : null}
    </>
  )
}
