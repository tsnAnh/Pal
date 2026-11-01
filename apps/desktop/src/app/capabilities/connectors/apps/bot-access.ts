import type { McpServerSummary } from '@hermes/shared'

import { type McpCatalogEntry, type ProfileScope, profileScopeKey } from '@/hermes'
import { queryClient } from '@/lib/query-client'

import { installBundledEntry } from '../../mcp/install-catalog-entry'
import { type ConnectorPolicyView, memberEnables, memberRevision, orgLocks, readPolicy } from '../data/join'
import { connectorsPolicyQueryKey, invalidateConnectors } from '../data/keys'
import { configureProfileMcp, connectorPolicy, listMcpServers, setConnectorPolicy } from '../data/rpc'
import type { ConnectorCardModel } from '../types'

export type AppRef = { kind: 'hosted'; slug: string } | { kind: 'local'; name: string }

export type BotAccess = 'needsSignIn' | 'off' | 'on' | 'unknown'

export interface AppBot {
  id: string
  label: string
  scope: ProfileScope
}

export interface BotAppsState {
  mcp: null | readonly McpServerSummary[]
  policy: ConnectorPolicyView | null
}

export type BotAppFailure = 'failed' | 'needsSetup' | 'rulesReadOnly'

export class BotAppError extends Error {
  readonly kind: BotAppFailure

  constructor(kind: BotAppFailure, message: string) {
    super(message)
    this.name = 'BotAppError'
    this.kind = kind
  }
}

const POLICY_STALE_MS = 30_000

const accessChanges = new Map<string, Promise<void>>()

function serialiseAccessChange(scope: ProfileScope, task: () => Promise<void>): Promise<void> {
  const key = profileScopeKey(scope)
  const run = (accessChanges.get(key) ?? Promise.resolve()).then(task)

  const tail = run.then(
    () => undefined,
    () => undefined
  )

  accessChanges.set(key, tail)

  void tail.then(() => {
    if (accessChanges.get(key) === tail) {
      accessChanges.delete(key)
    }
  })

  return run
}

export function appRefOf(card: ConnectorCardModel): AppRef {
  if (card.ways.hosted) {
    return { kind: 'hosted', slug: card.slug }
  }

  return { kind: 'local', name: card.ways.local?.serverName ?? card.ways.local?.entryName ?? card.slug }
}

export function botAccessFor(state: BotAppsState, ref: AppRef): BotAccess {
  if (ref.kind === 'hosted') {
    if (state.policy === null) {
      return 'unknown'
    }

    return memberEnables(state.policy, ref.slug) && !orgLocks(state.policy, ref.slug) ? 'on' : 'off'
  }

  if (state.mcp === null) {
    return 'unknown'
  }

  const server = state.mcp.find(row => row.name === ref.name && row.source === 'config')

  if (!server?.enabled) {
    return 'off'
  }

  return server.auth === 'oauth' && server.oauth_tokens_present === false ? 'needsSignIn' : 'on'
}

export function botsUsing(
  ref: AppRef,
  bots: readonly AppBot[],
  states: Readonly<Record<string, BotAppsState | undefined>>
): AppBot[] {
  return bots.filter(bot => {
    const state = states[bot.id]

    return state !== undefined && ['needsSignIn', 'on'].includes(botAccessFor(state, ref))
  })
}

export async function readBotAppsState(scope: ProfileScope): Promise<BotAppsState> {
  const [policy, mcp] = await Promise.allSettled([
    queryClient.fetchQuery({
      queryFn: () => connectorPolicy(scope),
      queryKey: connectorsPolicyQueryKey(scope),
      staleTime: POLICY_STALE_MS
    }),
    listMcpServers(scope)
  ])

  return {
    mcp: mcp.status === 'fulfilled' ? mcp.value.servers : null,
    policy: policy.status === 'fulfilled' ? readPolicy(policy.value) : null
  }
}

async function setHostedAccess(scope: ProfileScope, slug: string, enabled: boolean): Promise<void> {
  const revision = memberRevision(readPolicy(await connectorPolicy(scope)))

  if (revision === undefined) {
    throw new BotAppError('rulesReadOnly', 'Connector rules cannot be changed for this agent.')
  }

  await setConnectorPolicy(scope, { connector: slug, enabled, type: 'connector' }, revision)
  invalidateConnectors(scope, 'list', 'policy')
}

export function enabledMcpNames(servers: readonly McpServerSummary[], name: string, enabled: boolean): string[] {
  const names = new Set(servers.filter(row => row.source === 'config' && row.enabled).map(row => row.name))

  if (enabled) {
    names.add(name)
  } else {
    names.delete(name)
  }

  return [...names]
}

async function setLocalAccess(
  scope: ProfileScope,
  name: string,
  enabled: boolean,
  entry: McpCatalogEntry | null
): Promise<void> {
  let servers = (await listMcpServers(scope)).servers

  if (enabled && !servers.some(row => row.name === name && row.source === 'config')) {
    if (!entry || entry.required_env.some(field => field.required)) {
      throw new BotAppError('needsSetup', 'This app needs setup before an agent can use it.')
    }

    await installBundledEntry(entry, {}, scope)
    servers = (await listMcpServers(scope)).servers
  }

  const result = await configureProfileMcp(scope, enabledMcpNames(servers, name, enabled))

  if (!result.ok || result.applied.mcp_servers === false) {
    throw new BotAppError('failed', 'The agent settings could not be saved.')
  }
}

export async function setBotAccess(
  scope: ProfileScope,
  ref: AppRef,
  enabled: boolean,
  entry: McpCatalogEntry | null
): Promise<void> {
  await serialiseAccessChange(scope, () =>
    ref.kind === 'hosted' ? setHostedAccess(scope, ref.slug, enabled) : setLocalAccess(scope, ref.name, enabled, entry)
  )
}
