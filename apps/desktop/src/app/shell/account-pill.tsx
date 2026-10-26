import { useStore } from '@nanostores/react'
import { type ReactNode, useState } from 'react'
import { useNavigate } from 'react-router'

import { useConnectionSwitch } from '@/app/chat/sidebar/connection-switcher'
import { hudTargetSessionId } from '@/app/hud/handoff'
import { Codicon } from '@/components/ui/codicon'
import { DropdownMenu, DropdownMenuContent, DropdownMenuTrigger } from '@/components/ui/dropdown-menu'
import { Tip } from '@/components/ui/tooltip'
import { useI18n } from '@/i18n'
import { triggerHaptic } from '@/lib/haptics'
import { profileColorSoft, resolveProfileColor } from '@/lib/profile-color'
import { profileShortLabel } from '@/lib/profile-short-label'
import { cn } from '@/lib/utils'
import { $botChromeless } from '@/store/bot-surface'
import { $defaultProfileRoute } from '@/store/default-profile'
import { toggleHud } from '@/store/hud'
import { $interfaceMode, shownInMode } from '@/store/interface-mode'
import {
  $profileColors,
  $profiles,
  normalizeProfileKey,
  profileLabel,
  refreshActiveProfile,
  refreshProfiles,
  selectProfile
} from '@/store/profile'
import { TITLEBAR_FIXED_TOOLS } from '@/store/titlebar-app-actions'

import { CreateProfileDialog } from '../profiles/create-profile-dialog'
import { CAPABILITIES_ROUTE, navigateToWorkspacePage } from '../routes'

import { AccountMenuRows, MENU_SURFACE_CLASS } from './account-menu'

const PILL_CLASS =
  'flex h-8 items-center rounded-full border border-(--ui-stroke-secondary) bg-(--bot-control-fill,var(--chrome-action-hover)) text-foreground'

const WORD_BREAK = /[\s._-]+/

function initialsOf(label: string): string {
  const words = label.split(WORD_BREAK).filter(Boolean)

  return words.slice(0, 2).map(profileShortLabel).join('').toUpperCase()
}

function useAccountIdentity() {
  const route = useStore($defaultProfileRoute)
  const profiles = useStore($profiles)
  const colors = useStore($profileColors)
  const name = normalizeProfileKey(route?.profile ?? profiles.find(profile => profile.is_default)?.name)
  const profile = profiles.find(candidate => candidate.name === name)
  const label = profile ? profileLabel(profile) : name

  return { color: resolveProfileColor(name, colors), initials: initialsOf(label), label }
}

function QuickTool({ icon, label, onSelect }: { icon: string; label: string; onSelect: () => void }) {
  return (
    <Tip label={label} placement="control">
      <button
        aria-label={label}
        className="grid size-6.5 shrink-0 place-items-center rounded-full text-(--ui-text-secondary) transition-colors hover:bg-(--chrome-action-hover) hover:text-foreground"
        onClick={onSelect}
        type="button"
      >
        <Codicon className="leading-none" name={icon} size="1rem" />
      </button>
    </Tip>
  )
}

function QuickPill({ children }: { children: ReactNode }) {
  return (
    <div className={cn(PILL_CLASS, 'shrink-0 gap-0.5 px-1.5')} data-slot="account-quick-tools">
      {children}
    </div>
  )
}

function AccountDock({ className }: { className?: string }) {
  const { t } = useI18n()
  const navigate = useNavigate()
  const identity = useAccountIdentity()
  const profiles = useStore($profiles)
  const interfaceMode = useStore($interfaceMode)
  const [createOpen, setCreateOpen] = useState(false)
  const [menuOpen, setMenuOpen] = useState(false)
  const connectionSwitch = useConnectionSwitch()
  const showHud = shownInMode(interfaceMode)(TITLEBAR_FIXED_TOOLS.hud)

  return (
    <div
      className={cn(
        'mt-auto flex shrink-0 items-center gap-1.5 px-2 pb-2 pt-2 [-webkit-app-region:no-drag]',
        className
      )}
      data-slot="account-dock"
    >
      <DropdownMenu
        onOpenChange={open => {
          setMenuOpen(open)

          if (open) {
            void refreshProfiles().catch(() => undefined)
          }
        }}
        open={menuOpen}
      >
        <DropdownMenuTrigger asChild>
          <button
            className={cn(
              PILL_CLASS,
              'min-w-0 flex-1 gap-2.5 py-0 pl-1 pr-2.5 text-left transition-colors hover:bg-(--bot-row-active,var(--ui-control-hover-background)) data-[state=open]:bg-(--bot-row-active,var(--ui-control-hover-background))'
            )}
            data-slot="account-pill"
            type="button"
          >
            <span
              aria-hidden="true"
              className="grid size-5.5 shrink-0 place-items-center rounded-full bg-(--ui-bg-quaternary) text-[0.6875rem] font-semibold leading-none"
              style={
                identity.color
                  ? { backgroundColor: profileColorSoft(identity.color, 26), color: identity.color }
                  : undefined
              }
            >
              {identity.initials}
            </span>
            <span className="min-w-0 flex-1 truncate text-[0.8125rem] font-medium leading-5">{identity.label}</span>
          </button>
        </DropdownMenuTrigger>
        <DropdownMenuContent
          align="start"
          className={MENU_SURFACE_CLASS}
          data-slot="account-menu"
          side="top"
          sideOffset={8}
        >
          <AccountMenuRows
            connectionSwitch={connectionSwitch}
            onClose={() => setMenuOpen(false)}
            onCreateProfile={() => setCreateOpen(true)}
          />
        </DropdownMenuContent>
      </DropdownMenu>

      <QuickPill>
        <QuickTool
          icon="plug"
          label={t.connectorsPage.title}
          onSelect={() => navigateToWorkspacePage(navigate, `${CAPABILITIES_ROUTE}?tab=connectors`)}
        />
        {showHud ? (
          <QuickTool
            icon="comment-discussion"
            label={t.titlebar.enterHud}
            onSelect={() => {
              triggerHaptic('open')
              toggleHud(hudTargetSessionId())
            }}
          />
        ) : null}
      </QuickPill>

      {connectionSwitch.dialog}

      <CreateProfileDialog
        onClose={() => setCreateOpen(false)}
        onCreated={async name => {
          await refreshActiveProfile()
          selectProfile(name)
        }}
        open={createOpen}
        profiles={profiles}
      />
    </div>
  )
}

export function AccountPill({ className }: { className?: string }) {
  const chromeless = useStore($botChromeless)

  return chromeless ? <AccountDock className={className} /> : null
}
