import { useStore } from '@nanostores/react'
import { useState } from 'react'
import { useNavigate } from 'react-router'

import { useConnectionSwitch } from '@/app/chat/sidebar/connection-switcher'
import { Codicon } from '@/components/ui/codicon'
import { DropdownMenu, DropdownMenuContent, DropdownMenuTrigger } from '@/components/ui/dropdown-menu'
import { Tip } from '@/components/ui/tooltip'
import { useI18n } from '@/i18n'
import { profileColorSoft, resolveProfileColor } from '@/lib/profile-color'
import { profileShortLabel } from '@/lib/profile-short-label'
import { cn } from '@/lib/utils'
import { $botChromeless } from '@/store/bot-surface'
import { $defaultProfileRoute } from '@/store/default-profile'
import {
  $profileColors,
  $profiles,
  normalizeProfileKey,
  profileLabel,
  refreshActiveProfile,
  refreshProfiles,
  selectProfile
} from '@/store/profile'

import { CreateProfileDialog } from '../profiles/create-profile-dialog'
import { CAPABILITIES_ROUTE, navigateToWorkspacePage } from '../routes'

import { AccountMenuRows, MENU_SURFACE_CLASS } from './account-menu'

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

interface AccountPillProps {
  appsLabel?: string
  className?: string
  displayName?: string
  onOpenApps?: () => void
}

const CIRCLE_CLASS =
  'grid size-10 shrink-0 place-items-center rounded-full bg-(--bot-control-fill,var(--chrome-action-hover)) p-0 text-(--ui-text-secondary) transition-colors hover:text-foreground'

function AccountDock({ appsLabel, className, displayName, onOpenApps }: AccountPillProps) {
  const { t } = useI18n()
  const navigate = useNavigate()
  const identity = useAccountIdentity()
  const profiles = useStore($profiles)
  const [createOpen, setCreateOpen] = useState(false)
  const [menuOpen, setMenuOpen] = useState(false)
  const connectionSwitch = useConnectionSwitch()
  const accountLabel = displayName?.trim() || identity.label
  const accountInitials = displayName?.trim() ? initialsOf(accountLabel) : identity.initials
  const openApps = onOpenApps ?? (() => navigateToWorkspacePage(navigate, `${CAPABILITIES_ROUTE}?tab=connectors`))
  const appsAria = appsLabel ?? t.connectorsPage.title

  return (
    <div
      className={cn(
        'mt-auto flex shrink-0 items-center gap-2 px-3 pb-3 pt-2 [-webkit-app-region:no-drag]',
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
            className="flex h-12 min-w-0 flex-1 items-center gap-3 rounded-[14px] px-0 text-left text-foreground transition-colors hover:bg-[color-mix(in_srgb,var(--bot-row-active,var(--ui-control-hover-background))_55%,transparent)] data-[state=open]:bg-(--bot-row-active,var(--ui-control-hover-background))"
            data-slot="account-pill"
            type="button"
          >
            <span
              aria-hidden="true"
              className="grid size-10 shrink-0 place-items-center rounded-full bg-(--ui-bg-quaternary) text-[0.9375rem] font-semibold leading-none"
              data-slot="account-initials"
              style={
                identity.color
                  ? { backgroundColor: profileColorSoft(identity.color, 26), color: identity.color }
                  : undefined
              }
            >
              {accountInitials}
            </span>
            <span className="min-w-0 flex-1 truncate text-[0.9375rem] font-normal leading-5">{accountLabel}</span>
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

      <Tip label={appsAria} placement="control">
        <button
          aria-label={appsAria}
          className={CIRCLE_CLASS}
          data-slot="account-apps"
          onClick={openApps}
          type="button"
        >
          <Codicon className="leading-none" name="extensions" size="1.25rem" />
        </button>
      </Tip>

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

export function AccountPill(props: AccountPillProps) {
  const chromeless = useStore($botChromeless)

  return chromeless ? <AccountDock {...props} /> : null
}
