import { useStore } from '@nanostores/react'
import { type ReactNode } from 'react'
import { useNavigate } from 'react-router'

import { ConnectionLabel, type ConnectionSwitch } from '@/app/chat/sidebar/connection-switcher'
import { toggleLayoutEditMode } from '@/components/pane-shell/edit-mode'
import { revealTreePane } from '@/components/pane-shell/tree/store'
import { StatusDot, type StatusTone } from '@/components/status-dot'
import { Badge } from '@/components/ui/badge'
import { Codicon } from '@/components/ui/codicon'
import {
  DropdownMenuItem,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger
} from '@/components/ui/dropdown-menu'
import { ProfileGlyph } from '@/components/ui/profile-glyph'
import { useContributions } from '@/contrib/react/use-contributions'
import { type Translations, useI18n } from '@/i18n'
import { openExternalLink } from '@/lib/external-link'
import { triggerHaptic } from '@/lib/haptics'
import { useKeybindHint } from '@/lib/keybinds/use-keybind-hint'
import { resolveProfileColor } from '@/lib/profile-color'
import { cn } from '@/lib/utils'
import { $botsOnly } from '@/store/bot-surface'
import { $freeTierSignInOpen, $freeTierStatus, FREE_TIER_MODEL } from '@/store/free-tier'
import { openFreeTierSignIn } from '@/store/free-tier-sign-in'
import { $interfaceMode, shownInMode } from '@/store/interface-mode'
import { $fileBrowserOpen, $leftSideOpen, toggleLeftSide, togglePanesFlipped, toggleRightSide } from '@/store/layout'
import {
  $activeGatewayProfile,
  $profileColors,
  $profiles,
  normalizeProfileKey,
  profileLabel,
  selectProfile
} from '@/store/profile'
import { requestSendDiagnostics, SUPPORT_LINKS } from '@/store/send-diagnostics'
import { $gatewayState } from '@/store/session'
import { toggleStatusbarVisible } from '@/store/statusbar-prefs'
import { TITLEBAR_FIXED_TOOLS } from '@/store/titlebar-app-actions'

import { COMMAND_CENTER_ROUTE, navigateToWorkspacePage, PROFILES_ROUTE, SETTINGS_ROUTE } from '../routes'

import { GatewayMenuPanel } from './gateway-menu-panel'
import { useGatewayMenuSnapshot } from './hooks/use-gateway-menu-snapshot'
import { useSidebarPaneEntries } from './sidebar-pane-switcher'
import type { TitlebarTool } from './titlebar-controls'

export const MENU_ROW_CLASS = 'gap-3 rounded-[12px] px-3 py-2 text-[0.9375rem] leading-5 text-foreground'

export const MENU_SURFACE_CLASS =
  'w-[min(18.5rem,calc(100vw-1.5rem))] rounded-[16px] border-(--ui-stroke-secondary) bg-[color-mix(in_srgb,var(--ui-bg-elevated)_97%,transparent)] p-1.5 shadow-lg'

const MENU_SEPARATOR_CLASS = 'mx-1 my-1.5'

function RowIcon({ name }: { name: string }) {
  return (
    <span className="grid size-5 shrink-0 place-items-center text-(--ui-text-secondary)">
      <Codicon className="leading-none" name={name} size="1.25rem" />
    </span>
  )
}

function KeybindHint({ actionId }: { actionId: string }) {
  const hint = useKeybindHint(actionId)

  return hint ? <span className="shrink-0 text-(--ui-text-tertiary)">{hint}</span> : null
}

function MenuRow({
  disabled,
  icon,
  label,
  onSelect,
  trailing
}: {
  disabled?: boolean
  icon: ReactNode | string
  label: ReactNode
  onSelect: () => void
  trailing?: ReactNode
}) {
  return (
    <DropdownMenuItem className={MENU_ROW_CLASS} disabled={disabled} onSelect={onSelect}>
      {typeof icon === 'string' ? (
        <RowIcon name={icon} />
      ) : (
        <span className="grid size-5 shrink-0 place-items-center">{icon}</span>
      )}
      <span className="min-w-0 flex-1 truncate">{label}</span>
      {trailing}
    </DropdownMenuItem>
  )
}

function useContributedTools(): TitlebarTool[] {
  const left = useContributions('titleBar.tools.left')
  const right = useContributions('titleBar.tools.right')
  const mode = useStore($interfaceMode)
  const shown = shownInMode(mode)

  return [...left, ...right]
    .map(contribution => contribution.data as TitlebarTool)
    .filter(tool => Boolean(tool) && !tool.hidden && shown(tool))
}

function ContributedToolRows() {
  const navigate = useNavigate()
  const tools = useContributedTools()

  return tools.map(tool => (
    <MenuRow
      disabled={tool.disabled}
      icon={tool.icon}
      key={tool.id}
      label={tool.title ?? tool.label}
      onSelect={() => {
        if (tool.href) {
          openExternalLink(tool.href)

          return
        }

        if (tool.to) {
          navigate(tool.to)
        }

        tool.onSelect?.()
      }}
    />
  ))
}

function SidebarRows() {
  const { t } = useI18n()
  const botsOnly = useStore($botsOnly)
  const leftOpen = useStore($leftSideOpen)
  const rightOpen = useStore($fileBrowserOpen)
  const mode = useStore($interfaceMode)
  const entries = useSidebarPaneEntries()
  const shown = shownInMode(mode)
  const activeEntry = entries.find(entry => entry.active)

  return (
    <>
      {botsOnly ? null : (
        <MenuRow
          icon="layout-sidebar-left"
          label={leftOpen ? t.titlebar.hideSidebar : t.titlebar.showSidebar}
          onSelect={() => {
            triggerHaptic('tap')
            toggleLeftSide()
          }}
          trailing={<KeybindHint actionId="view.toggleSidebar" />}
        />
      )}
      {!botsOnly && entries.length > 1 ? (
        <DropdownMenuSub>
          <DropdownMenuSubTrigger className={MENU_ROW_CLASS}>
            <RowIcon name="layout-panel-left" />
            <span className="min-w-0 flex-1 truncate">{t.sidebar.paneSwitcherAria}</span>
            {activeEntry ? <span className="shrink-0 text-(--ui-text-tertiary)">{activeEntry.label}</span> : null}
          </DropdownMenuSubTrigger>
          <DropdownMenuSubContent className={cn(MENU_SURFACE_CLASS, 'w-56')}>
            <DropdownMenuRadioGroup value={activeEntry?.id ?? ''}>
              {entries.map(entry => (
                <DropdownMenuRadioItem
                  className={MENU_ROW_CLASS}
                  key={entry.id}
                  onSelect={() => revealTreePane(entry.id)}
                  value={entry.id}
                >
                  <RowIcon name={entry.icon} />
                  <span className="min-w-0 flex-1 truncate">{entry.label}</span>
                </DropdownMenuRadioItem>
              ))}
            </DropdownMenuRadioGroup>
          </DropdownMenuSubContent>
        </DropdownMenuSub>
      ) : null}
      {shown(TITLEBAR_FIXED_TOOLS['flip-panes']) ? (
        <MenuRow
          icon="arrow-swap"
          label={t.titlebar.swapSidebarSides}
          onSelect={() => {
            triggerHaptic('tap')
            togglePanesFlipped()
          }}
          trailing={<KeybindHint actionId="view.flipPanes" />}
        />
      ) : null}
      {shown(TITLEBAR_FIXED_TOOLS['right-sidebar']) ? (
        <MenuRow
          icon="layout-sidebar-right"
          label={rightOpen ? t.titlebar.hideRightSidebar : t.titlebar.showRightSidebar}
          onSelect={() => {
            triggerHaptic('tap')
            toggleRightSide()
          }}
          trailing={<KeybindHint actionId="view.toggleRightSidebar" />}
        />
      ) : null}
    </>
  )
}

function StatusbarRow() {
  const { t } = useI18n()

  return (
    <MenuRow
      icon="layout-statusbar"
      label={t.keybinds.actions['view.toggleStatusbar']}
      onSelect={() => {
        triggerHaptic('tap')
        toggleStatusbarVisible()
      }}
      trailing={<KeybindHint actionId="view.toggleStatusbar" />}
    />
  )
}

function ConnectionRows({ connectionSwitch }: { connectionSwitch: ConnectionSwitch }) {
  const { t } = useI18n()
  const navigate = useNavigate()
  const { activeConnectionId, choose, connections } = connectionSwitch

  if (connections.length <= 1) {
    return null
  }

  const active = connections.find(connection => connection.id === activeConnectionId)

  return (
    <DropdownMenuSub>
      <DropdownMenuSubTrigger className={MENU_ROW_CLASS} data-slot="account-connection-switcher">
        <RowIcon name="remote" />
        <span className="min-w-0 flex-1 truncate">{t.settings.connections.title}</span>
        {active ? <span className="max-w-24 shrink-0 truncate text-(--ui-text-tertiary)">{active.label}</span> : null}
      </DropdownMenuSubTrigger>
      <DropdownMenuSubContent className={cn(MENU_SURFACE_CLASS, 'w-64')}>
        <DropdownMenuRadioGroup
          className="dt-portal-scrollbar max-h-72 overflow-y-auto"
          onValueChange={choose}
          value={activeConnectionId ?? ''}
        >
          {connections.map(connection => (
            <DropdownMenuRadioItem className={MENU_ROW_CLASS} key={connection.id} value={connection.id}>
              <ConnectionLabel connection={connection} />
            </DropdownMenuRadioItem>
          ))}
        </DropdownMenuRadioGroup>
        <DropdownMenuSeparator className={MENU_SEPARATOR_CLASS} />
        <MenuRow
          icon="settings-gear"
          label={t.profiles.connectGateway}
          onSelect={() => navigate(`${SETTINGS_ROUTE}?tab=connections`)}
        />
      </DropdownMenuSubContent>
    </DropdownMenuSub>
  )
}

function GatewayHealthPanel({ gatewayState, onClose }: { gatewayState: string; onClose: () => void }) {
  const navigate = useNavigate()
  const { inferenceStatus, statusSnapshot } = useGatewayMenuSnapshot(gatewayState)

  return (
    <GatewayMenuPanel
      gatewayState={gatewayState}
      inferenceStatus={inferenceStatus}
      onClose={onClose}
      onOpenSystem={() => navigate(`${COMMAND_CENTER_ROUTE}?section=system`)}
      statusSnapshot={statusSnapshot}
    />
  )
}

function GatewayHealthRows({ onClose }: { onClose: () => void }) {
  const { t } = useI18n()
  const gatewayState = useStore($gatewayState)
  const copy = t.shell.gatewayMenu

  const [tone, stateLabel]: [StatusTone, string] =
    gatewayState === 'open'
      ? ['good', copy.connected]
      : gatewayState === 'connecting'
        ? ['warn', copy.connecting]
        : ['bad', copy.offline]

  return (
    <DropdownMenuSub>
      <DropdownMenuSubTrigger className={MENU_ROW_CLASS} data-slot="account-gateway-health">
        <span className="grid size-5 shrink-0 place-items-center">
          <StatusDot className="size-2" tone={tone} />
        </span>
        <span className="min-w-0 flex-1 truncate">{t.shell.statusbar.backend}</span>
        <span className="shrink-0 text-(--ui-text-tertiary)">{stateLabel}</span>
      </DropdownMenuSubTrigger>
      <DropdownMenuSubContent className={cn(MENU_SURFACE_CLASS, 'w-80 p-0')} data-slot="account-gateway-panel">
        <GatewayHealthPanel gatewayState={gatewayState} onClose={onClose} />
      </DropdownMenuSubContent>
    </DropdownMenuSub>
  )
}

function FreeTierRow() {
  const { t } = useI18n()
  const signInOpen = useStore($freeTierSignInOpen)
  const status = useStore($freeTierStatus)

  if (!signInOpen) {
    return null
  }

  return (
    <MenuRow
      icon="account"
      label={t.freeTier.statusLabel(status?.model ?? FREE_TIER_MODEL)}
      onSelect={() => openFreeTierSignIn()}
      trailing={
        <Badge className="leading-none" size="xs" variant="solid">
          {t.freeTier.signIn}
        </Badge>
      }
    />
  )
}

function ProfileRows({ onCreate }: { onCreate: () => void }) {
  const { t } = useI18n()
  const navigate = useNavigate()
  const profiles = useStore($profiles)
  const colors = useStore($profileColors)
  const activeProfile = normalizeProfileKey(useStore($activeGatewayProfile))
  const active = profiles.find(profile => profile.name === activeProfile)

  return (
    <DropdownMenuSub>
      <DropdownMenuSubTrigger className={MENU_ROW_CLASS}>
        <RowIcon name="organization" />
        <span className="min-w-0 flex-1 truncate">{t.profiles.title}</span>
        <span className="max-w-24 shrink-0 truncate text-(--ui-text-tertiary)">
          {active ? profileLabel(active) : activeProfile}
        </span>
      </DropdownMenuSubTrigger>
      <DropdownMenuSubContent className={cn(MENU_SURFACE_CLASS, 'w-64')}>
        <DropdownMenuRadioGroup value={activeProfile}>
          {profiles.map(profile => (
            <DropdownMenuRadioItem
              className={MENU_ROW_CLASS}
              key={profile.name}
              onSelect={() => selectProfile(profile.name)}
              value={profile.name}
            >
              <span aria-hidden="true" className="grid size-5 shrink-0 place-items-center">
                <ProfileGlyph
                  className="size-5 rounded-md text-[0.6875rem]"
                  color={resolveProfileColor(profile.name, colors)}
                  isDefault={profile.is_default}
                  name={profileLabel(profile)}
                />
              </span>
              <span className="min-w-0 flex-1 truncate">{profileLabel(profile)}</span>
            </DropdownMenuRadioItem>
          ))}
        </DropdownMenuRadioGroup>
        {profiles.length ? <DropdownMenuSeparator className={MENU_SEPARATOR_CLASS} /> : null}
        <MenuRow icon="add" label={t.profiles.newProfile} onSelect={onCreate} />
        <MenuRow
          icon="settings-gear"
          label={t.profiles.manageProfiles}
          onSelect={() => navigateToWorkspacePage(navigate, PROFILES_ROUTE)}
        />
      </DropdownMenuSubContent>
    </DropdownMenuSub>
  )
}

function supportLabel(copy: Translations['sendDiagnostics'], key: (typeof SUPPORT_LINKS)[number]['key']): string {
  return copy.links[key]
}

const SUPPORT_ICONS = { discord: 'comment-discussion', github: 'github', portal: 'question' } as const

export function AccountMenuRows({
  connectionSwitch,
  onClose,
  onCreateProfile
}: {
  connectionSwitch: ConnectionSwitch
  onClose: () => void
  onCreateProfile: () => void
}) {
  const { t } = useI18n()
  const navigate = useNavigate()

  return (
    <>
      <MenuRow
        icon="settings-gear"
        label={t.commandCenter.settings}
        onSelect={() => {
          triggerHaptic('open')
          navigate(SETTINGS_ROUTE)
        }}
        trailing={<KeybindHint actionId="nav.settings" />}
      />
      <MenuRow
        icon="credit-card"
        label={t.settings.nav.billing}
        onSelect={() => navigate(`${SETTINGS_ROUTE}?tab=billing`)}
      />
      <MenuRow
        icon="layout"
        label={t.titlebar.layoutEditor}
        onSelect={() => {
          triggerHaptic('open')
          toggleLayoutEditMode()
        }}
      />
      <SidebarRows />
      <StatusbarRow />
      <ContributedToolRows />
      <DropdownMenuSeparator className={MENU_SEPARATOR_CLASS} />
      <ConnectionRows connectionSwitch={connectionSwitch} />
      <GatewayHealthRows onClose={onClose} />
      <FreeTierRow />
      <ProfileRows onCreate={onCreateProfile} />
      {SUPPORT_LINKS.map(link => (
        <MenuRow
          icon={SUPPORT_ICONS[link.key]}
          key={link.key}
          label={supportLabel(t.sendDiagnostics, link.key)}
          onSelect={() => openExternalLink(link.url)}
          trailing={<Codicon className="shrink-0 text-(--ui-text-tertiary)" name="link-external" size="0.875rem" />}
        />
      ))}
      <MenuRow icon="bug" label={t.sendDiagnostics.title} onSelect={() => requestSendDiagnostics()} />
    </>
  )
}
