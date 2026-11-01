import { connectorIconUrl } from '@/lib/connector-tools'

import type { ConnectorCardModel, HostedPhase } from '../types'

export type AppStatus = 'connected' | 'needsSignIn' | 'notConnected'

export type AppAvailability = 'available' | 'comingSoon' | 'unknown'

export type AppAction = 'connect' | 'none' | 'reconnect' | 'setup' | 'turnOn' | 'waiting'

export interface CuratedApp {
  id: string
  name: string
  names: readonly string[]
  slugs: readonly string[]
}

export const CURATED_APPS: readonly CuratedApp[] = [
  { id: 'gmail', name: 'Gmail', names: ['gmail'], slugs: ['gmail'] },
  {
    id: 'googlecalendar',
    name: 'Google Calendar',
    names: ['google-calendar'],
    slugs: ['googlecalendar', 'google-calendar']
  },
  { id: 'googledrive', name: 'Google Drive', names: ['google-drive'], slugs: ['googledrive', 'google-drive'] },
  { id: 'slack', name: 'Slack', names: ['slack'], slugs: ['slack'] },
  { id: 'notion', name: 'Notion', names: ['notion'], slugs: ['notion'] },
  { id: '1password', name: '1Password', names: ['1password', 'onepassword'], slugs: ['1password', 'onepassword'] }
]

export interface AppEntry {
  action: AppAction
  availability: AppAvailability
  card: ConnectorCardModel | null
  curated: boolean
  description?: string
  iconUrl?: string
  id: string
  name: string
  offByOrg: boolean
  pending: boolean
  status: AppStatus
}

export interface AppsCatalog {
  curated: AppEntry[]
  others: AppEntry[]
}

export function appStatus(card: ConnectorCardModel): AppStatus {
  if (card.state === 'connected') {
    return 'connected'
  }

  if (card.state === 'expired' || card.reason?.key === 'serverNeedsAuth') {
    return 'needsSignIn'
  }

  return 'notConnected'
}

export function appAction(card: ConnectorCardModel): AppAction {
  if (card.offBy === 'org') {
    return 'none'
  }

  switch (card.verb) {
    case 'connect':

    case 'tryAgain':
      return 'connect'

    case 'install':
      return card.ways.local?.needsEnv === true ? 'setup' : 'connect'

    case 'reconnect':

    case 'authenticate':
      return 'reconnect'

    case 'turnBackOn':
      return 'turnOn'

    case 'stopWaiting':
      return 'waiting'

    case 'openLogs':
      return 'setup'

    default:
      return 'none'
  }
}

function cardNames(card: ConnectorCardModel): string[] {
  return [card.slug, card.ways.local?.serverName, card.ways.local?.entryName].flatMap(name => (name ? [name] : []))
}

export function matchesCurated(app: CuratedApp, card: ConnectorCardModel): boolean {
  return cardNames(card).some(name => app.slugs.includes(name) || app.names.includes(name))
}

function entryOf(card: ConnectorCardModel, curated: boolean, name = card.name): AppEntry {
  return {
    action: appAction(card),
    availability: 'available',
    card,
    curated,
    description: card.description,
    iconUrl: card.ways.hosted ? connectorIconUrl(card.slug) : undefined,
    id: card.slug,
    name,
    offByOrg: card.offBy === 'org',
    pending: card.state === 'connecting',
    status: appStatus(card)
  }
}

function missingEntry(app: CuratedApp, phase: HostedPhase): AppEntry {
  return {
    action: 'none',
    availability: phase === 'ready' ? 'comingSoon' : 'unknown',
    card: null,
    curated: true,
    iconUrl: connectorIconUrl(app.slugs[0]),
    id: app.id,
    name: app.name,
    offByOrg: false,
    pending: false,
    status: 'notConnected'
  }
}

const byName = (a: AppEntry, b: AppEntry) => a.name.localeCompare(b.name)

export function isCatalogCard(card: ConnectorCardModel): boolean {
  return card.plugin === undefined && (card.ways.hosted !== null || card.inCatalog)
}

export interface BuildAppsInput {
  cards: readonly ConnectorCardModel[]
  catalogReady: boolean
  phase: HostedPhase
}

export function buildAppsCatalog({ cards, catalogReady, phase }: BuildAppsInput): AppsCatalog {
  const claimed = new Set<ConnectorCardModel>()

  const curated = CURATED_APPS.map(app => {
    const card = cards.find(candidate => isCatalogCard(candidate) && matchesCurated(app, candidate))

    if (!card) {
      return missingEntry(app, catalogReady ? phase : 'loading')
    }

    claimed.add(card)

    return entryOf(card, true, app.name)
  })

  const others = cards
    .filter(card => !claimed.has(card) && isCatalogCard(card))
    .map(card => entryOf(card, false))
    .sort(byName)

  return { curated, others }
}

export function filterApps(entries: readonly AppEntry[], query: string): AppEntry[] {
  const needle = query.trim().toLowerCase()

  if (needle === '') {
    return [...entries]
  }

  return entries.filter(entry => `${entry.name} ${entry.id} ${entry.description ?? ''}`.toLowerCase().includes(needle))
}
