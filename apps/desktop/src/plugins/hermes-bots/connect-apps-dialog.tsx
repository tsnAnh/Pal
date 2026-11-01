import type { AppBot, AppEntry, BotAppFailure, ConnectorAppsView } from '@hermes/plugin-sdk'
import * as sdk from '@hermes/plugin-sdk'
import {
  Button,
  cn,
  Codicon,
  ConnectorLogo,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DropdownMenuItem,
  filterApps,
  host,
  SearchField,
  Switch,
  useValue
} from '@hermes/plugin-sdk'
import { useMemo, useState } from 'react'

import { $connectApps, appBotsOf, closeConnectApps, connectAppsSupported, openConnectApps } from './connect-apps'
import { $lastRoster } from './data'
import { type BotsText, useBots } from './i18n'

const STATUS_DOT = {
  connected: 'bg-(--ui-green)',
  needsSignIn: 'bg-(--ui-orange)',
  notConnected: 'bg-(--ui-text-quaternary)'
} as const

export function ConnectAppsMenuItem() {
  const b = useBots()

  if (!connectAppsSupported) {
    return null
  }

  return (
    <DropdownMenuItem onSelect={() => openConnectApps()}>
      <Codicon className="mr-1.5" name="plug" />
      {b.connectApps.menu}
    </DropdownMenuItem>
  )
}

export function ConnectAppsDialog() {
  const b = useBots()
  const request = useValue($connectApps)

  if (!connectAppsSupported) {
    return null
  }

  return (
    <Dialog onOpenChange={next => !next && closeConnectApps()} open={request.open}>
      <DialogContent className="max-w-xl">
        <DialogHeader>
          <DialogTitle>{b.connectApps.title}</DialogTitle>
          <DialogDescription>{b.connectApps.description}</DialogDescription>
        </DialogHeader>
        {request.open ? <ConnectAppsBody focusBotId={request.botId} /> : null}
      </DialogContent>
    </Dialog>
  )
}

export function catalogScope() {
  const connectionId = host.state.connectionId.get()
  const profile = host.state.profile.get() || 'default'

  return connectionId ? { connectionId, profile } : profile
}

function ConnectAppsBody({ focusBotId }: { focusBotId: null | string }) {
  const b = useBots()
  const roster = useValue($lastRoster)
  const [query, setQuery] = useState('')
  const allBots = useMemo(() => appBotsOf(roster), [roster])
  const focus = allBots.find(bot => bot.id === focusBotId) ?? null
  const bots = focus ? [focus] : allBots
  const scope = useMemo(catalogScope, [])

  const view = sdk.useConnectorApps({
    bots,
    gateway: typeof host.getGateway === 'function' ? host.getGateway() : null,
    profile: scope
  })

  const curated = filterApps(view.catalog.curated, query)
  const others = filterApps(view.catalog.others, query)

  return (
    <div className="grid min-h-0 gap-3">
      <SearchField
        aria-label={b.connectApps.searchLabel}
        onChange={setQuery}
        placeholder={b.connectApps.searchPlaceholder}
        value={query}
      />
      <div className="grid max-h-[26rem] min-h-40 content-start gap-3 overflow-y-auto overscroll-contain pr-1">
        <PhaseNotice view={view} />
        {view.loading ? <p className="text-sm text-(--ui-text-tertiary)">{b.connectApps.loading}</p> : null}
        <AppSection apps={curated} bots={bots} focused={focus !== null} title={b.connectApps.popular} view={view} />
        <AppSection apps={others} bots={bots} focused={focus !== null} title={b.connectApps.moreApps} view={view} />
        {!view.loading && curated.length + others.length === 0 ? (
          <p className="text-sm text-(--ui-text-tertiary)">{b.connectApps.noResults}</p>
        ) : null}
      </div>
    </div>
  )
}

function PhaseNotice({ view }: { view: ConnectorAppsView }) {
  const b = useBots()
  const copy = b.connectApps.notice

  if (view.phase === 'signedOut') {
    return <p className="text-xs text-(--ui-text-secondary)">{copy.signedOut}</p>
  }

  if (view.phase === 'unavailable') {
    return <p className="text-xs text-(--ui-text-secondary)">{copy.unavailable}</p>
  }

  if (!view.failed) {
    return null
  }

  return (
    <div className="flex items-center justify-between gap-3">
      <p className="text-xs text-(--ui-text-secondary)">{copy.failed}</p>
      <Button onClick={view.refetch} size="xs" variant="secondary">
        {copy.retry}
      </Button>
    </div>
  )
}

interface AppSectionProps {
  apps: AppEntry[]
  bots: AppBot[]
  focused: boolean
  title: string
  view: ConnectorAppsView
}

function AppSection({ apps, bots, focused, title, view }: AppSectionProps) {
  if (apps.length === 0) {
    return null
  }

  return (
    <section className="grid gap-1.5">
      <h3 className="text-[0.6875rem] font-medium tracking-wide text-(--ui-text-tertiary) uppercase">{title}</h3>
      {apps.map(app => (
        <AppRow app={app} bots={bots} focused={focused} key={app.id} view={view} />
      ))}
    </section>
  )
}

function statusLine(b: BotsText, app: AppEntry): string {
  if (app.availability === 'comingSoon') {
    return b.connectApps.comingSoon
  }

  if (app.availability === 'unknown') {
    return b.connectApps.unknown
  }

  if (app.offByOrg) {
    return b.connectApps.offByOrg
  }

  return app.pending ? b.connectApps.waiting : b.connectApps.status[app.status]
}

function usedByLine(b: BotsText, app: AppEntry, used: AppBot[]): null | string {
  if (app.status === 'notConnected' || app.card === null) {
    return null
  }

  return used.length > 0 ? b.connectApps.usedBy(used.map(bot => bot.label).join(', ')) : b.connectApps.usedByNone
}

interface AppRowProps {
  app: AppEntry
  bots: AppBot[]
  focused: boolean
  view: ConnectorAppsView
}

function AppRow({ app, bots, focused, view }: AppRowProps) {
  const b = useBots()
  const [open, setOpen] = useState(focused)
  const available = app.availability === 'available'
  const dot = available ? STATUS_DOT[app.status] : STATUS_DOT.notConnected
  const usedLine = usedByLine(b, app, view.usedBy(app))
  const showBots = available && app.status === 'connected' && bots.length > 0

  return (
    <div
      className="grid gap-2 rounded-lg border border-(--ui-stroke-quaternary) bg-(--ui-bg-elevated) p-3"
      data-app={app.id}
      data-availability={app.availability}
      data-status={app.status}
    >
      <div className="flex items-center gap-3">
        <ConnectorLogo
          className={cn('size-9 shrink-0 rounded-[9px]', !available && 'opacity-60')}
          connector={{ iconUrl: app.iconUrl, name: app.id, title: app.name }}
        />
        <div className="grid min-w-0 flex-1 gap-0.5">
          <span className="truncate text-[0.8125rem] font-semibold text-(--ui-text-primary)">{app.name}</span>
          <span className="flex min-w-0 items-center gap-1.5 text-[0.6875rem] text-(--ui-text-secondary)">
            <span aria-hidden className={cn('size-1.5 shrink-0 rounded-full', dot)} />
            <span className="truncate">{statusLine(b, app)}</span>
          </span>
          {usedLine ? <span className="truncate text-[0.6875rem] text-(--ui-text-tertiary)">{usedLine}</span> : null}
        </div>
        <RowAction
          app={app}
          busy={view.busyId === app.id}
          onOpenBots={() => setOpen(value => !value)}
          open={open}
          showBots={showBots && !focused}
          view={view}
        />
      </div>
      {showBots && open ? <BotAccessList app={app} bots={bots} view={view} /> : null}
    </div>
  )
}

interface RowActionProps {
  app: AppEntry
  busy: boolean
  onOpenBots: () => void
  open: boolean
  showBots: boolean
  view: ConnectorAppsView
}

const ACTION_LABEL = {
  connect: 'connect',
  reconnect: 'reconnect',
  setup: 'setup',
  turnOn: 'turnOn'
} as const

function RowAction({ app, busy, onOpenBots, open, showBots, view }: RowActionProps) {
  const b = useBots()
  const actions = b.connectApps.action

  if (app.availability !== 'available') {
    return null
  }

  if (app.action === 'waiting') {
    return (
      <Button onClick={() => view.connect(app)} size="xs" variant="secondary">
        {actions.cancel}
      </Button>
    )
  }

  if (app.action === 'none') {
    return showBots ? (
      <Button aria-expanded={open} onClick={onOpenBots} size="xs" variant="secondary">
        {b.connectApps.manageBots}
      </Button>
    ) : null
  }

  return (
    <Button
      disabled={busy}
      onClick={() => (app.action === 'setup' ? openSetup(app, view) : view.connect(app))}
      size="xs"
      variant={app.status === 'needsSignIn' ? 'default' : 'secondary'}
    >
      {actions[ACTION_LABEL[app.action]]}
    </Button>
  )
}

function openSetup(app: AppEntry, view: ConnectorAppsView) {
  closeConnectApps()
  view.openInSettings(app)
}

interface BotAccessListProps {
  app: AppEntry
  bots: AppBot[]
  view: ConnectorAppsView
}

function BotAccessList({ app, bots, view }: BotAccessListProps) {
  return (
    <ul className="grid gap-1 border-t border-(--ui-stroke-quaternary) pt-2">
      {bots.map(bot => (
        <BotAccessRow app={app} bot={bot} key={bot.id} view={view} />
      ))}
    </ul>
  )
}

function BotAccessRow({ app, bot, view }: { app: AppEntry; bot: AppBot; view: ConnectorAppsView }) {
  const b = useBots()
  const [pending, setPending] = useState(false)
  const [failure, setFailure] = useState<BotAppFailure | null>(null)
  const access = view.access(app, bot)

  const change = async (enabled: boolean) => {
    setPending(true)
    setFailure(null)
    setFailure(await view.setAccess(app, bot, enabled))
    setPending(false)
  }

  return (
    <li className="grid gap-1">
      <div className="flex items-center gap-2">
        <span className="min-w-0 flex-1 truncate text-xs text-(--ui-text-primary)">{bot.label}</span>
        {access === 'unknown' ? (
          <span className="text-[0.6875rem] text-(--ui-text-tertiary)">{b.connectApps.botUnknown}</span>
        ) : null}
        {access === 'needsSignIn' ? (
          <Button onClick={() => void view.signInBot(app, bot)} size="xs" variant="secondary">
            {b.connectApps.botSignIn}
          </Button>
        ) : null}
        <Switch
          aria-label={b.connectApps.useFor(bot.label)}
          checked={access === 'on' || access === 'needsSignIn'}
          disabled={pending || access === 'unknown'}
          onCheckedChange={next => void change(next)}
        />
      </div>
      {failure ? (
        <p className="text-[0.6875rem] text-destructive" role="alert">
          {b.connectApps.failure[failure]}
        </p>
      ) : null}
    </li>
  )
}
