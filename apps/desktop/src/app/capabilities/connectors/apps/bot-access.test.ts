import type { ConnectorPolicyGetResult, McpServerSummary } from '@hermes/shared'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { readPolicy } from '../data/join'
import type { ConnectorCardModel } from '../types'

const rpc = vi.hoisted(() => ({
  configureProfileMcp: vi.fn(),
  connectorPolicy: vi.fn(),
  listMcpServers: vi.fn(),
  setConnectorPolicy: vi.fn()
}))

const install = vi.hoisted(() => ({ installBundledEntry: vi.fn() }))

vi.mock('../data/rpc', () => rpc)
vi.mock('../../mcp/install-catalog-entry', () => install)

const { appRefOf, BotAppError, botAccessFor, botsUsing, enabledMcpNames, readBotAppsState, setBotAccess } =
  await import('./bot-access')

const REVISION = '01ARZ3NDEKTSV4RRFFQ69G5FAV'

const policyResult = (body: object): ConnectorPolicyGetResult =>
  // SAFETY: only the layers are read back by `readPolicy`.
  ({ effective: {}, layers: [{ body, kind: 'member', revision: REVISION }] }) as unknown as ConnectorPolicyGetResult

const server = (name: string, overrides: Partial<McpServerSummary> = {}): McpServerSummary => ({
  args: [],
  enabled: true,
  env: [],
  name,
  source: 'config',
  transport: 'http',
  ...overrides
})

const entry = (name: string, needsEnv = false) =>
  // SAFETY: the install path reads only `name` and `required_env`.
  ({ name, required_env: needsEnv ? [{ name: 'KEY', required: true }] : [] }) as never

const hostedRef = { kind: 'hosted', slug: 'gmail' } as const
const localRef = { kind: 'local', name: 'notion' } as const
const scope = { connectionId: null, profile: 'writer' }

beforeEach(() => {
  vi.clearAllMocks()
  rpc.configureProfileMcp.mockResolvedValue({ applied: { mcp_servers: true }, ok: true })
  rpc.setConnectorPolicy.mockResolvedValue({ revision: REVISION })
  install.installBundledEntry.mockResolvedValue(undefined)
})

describe('botAccessFor', () => {
  it('reads a hosted app as on unless the agent policy denies it', () => {
    const open = { mcp: null, policy: readPolicy(policyResult({ mode: 'unrestricted' })) }

    const denied = {
      mcp: null,
      policy: readPolicy(policyResult({ disabled_connectors: ['gmail'], mode: 'deny', tools: {} }))
    }

    expect(botAccessFor(open, hostedRef)).toBe('on')
    expect(botAccessFor(denied, hostedRef)).toBe('off')
  })

  it('reads a hosted app as off when only other apps are allowed', () => {
    const allow = { mcp: null, policy: readPolicy(policyResult({ connectors: ['slack'], mode: 'allow', tools: {} })) }

    expect(botAccessFor(allow, hostedRef)).toBe('off')
  })

  it('does not guess when a read failed', () => {
    expect(botAccessFor({ mcp: null, policy: null }, hostedRef)).toBe('unknown')
    expect(botAccessFor({ mcp: null, policy: null }, localRef)).toBe('unknown')
  })

  it('reads a local server by its enabled flag and its own sign-in', () => {
    const state = (row?: McpServerSummary) => ({ mcp: row ? [row] : [], policy: null })

    expect(botAccessFor(state(), localRef)).toBe('off')
    expect(botAccessFor(state(server('notion', { enabled: false })), localRef)).toBe('off')
    expect(botAccessFor(state(server('notion')), localRef)).toBe('on')

    expect(botAccessFor(state(server('notion', { auth: 'oauth', oauth_tokens_present: false })), localRef)).toBe(
      'needsSignIn'
    )

    expect(botAccessFor(state(server('notion', { auth: 'oauth', oauth_tokens_present: true })), localRef)).toBe('on')
  })

  it('ignores a plugin server that shares a name', () => {
    expect(botAccessFor({ mcp: [server('notion', { source: 'plugin' })], policy: null }, localRef)).toBe('off')
  })
})

describe('botsUsing', () => {
  it('lists the agents whose access is on, counting one that must sign in again', () => {
    const bots = ['a', 'b', 'c', 'd'].map(id => ({
      id,
      label: id.toUpperCase(),
      scope: { connectionId: null, profile: id }
    }))

    const states = {
      a: { mcp: [server('notion')], policy: null },
      b: { mcp: [server('notion', { enabled: false })], policy: null },
      c: { mcp: [server('notion', { auth: 'oauth', oauth_tokens_present: false })], policy: null },
      d: undefined
    }

    expect(botsUsing(localRef, bots, states).map(bot => bot.id)).toEqual(['a', 'c'])
  })
})

describe('appRefOf', () => {
  const card = (hosted: boolean, local: object | null) =>
    ({ slug: 'notion', ways: { hosted: hosted ? {} : null, local } }) as unknown as ConnectorCardModel

  it('prefers the hosted way and otherwise names the server', () => {
    expect(appRefOf(card(true, { serverName: 'notion' }))).toEqual({ kind: 'hosted', slug: 'notion' })
    expect(appRefOf(card(false, { serverName: 'notion-x' }))).toEqual({ kind: 'local', name: 'notion-x' })
    expect(appRefOf(card(false, { entryName: 'notion' }))).toEqual({ kind: 'local', name: 'notion' })
  })
})

describe('enabledMcpNames', () => {
  const servers = [server('a'), server('b', { enabled: false }), server('p', { source: 'plugin' })]

  it('adds the app to the enabled set and keeps the rest', () => {
    expect(enabledMcpNames(servers, 'b', true).sort()).toEqual(['a', 'b'])
  })

  it('removes the app and leaves the others alone', () => {
    expect(enabledMcpNames(servers, 'a', false)).toEqual([])
  })
})

describe('setBotAccess for a hosted app', () => {
  it('writes the agent policy at the agent scope with the revision it just read', async () => {
    rpc.connectorPolicy.mockResolvedValue(policyResult({ mode: 'unrestricted' }))

    await setBotAccess(scope, hostedRef, false, null)

    expect(rpc.setConnectorPolicy).toHaveBeenCalledWith(
      scope,
      { connector: 'gmail', enabled: false, type: 'connector' },
      REVISION
    )
  })

  it('refuses to write when the agent has no editable policy', async () => {
    rpc.connectorPolicy.mockResolvedValue({ effective: {}, layers: [] })

    await expect(setBotAccess(scope, hostedRef, true, null)).rejects.toMatchObject({ kind: 'rulesReadOnly' })
    expect(rpc.setConnectorPolicy).not.toHaveBeenCalled()
  })
})

describe('setBotAccess for a local app', () => {
  it('enables an installed server by rewriting the enabled list of that agent profile', async () => {
    rpc.listMcpServers.mockResolvedValue({ servers: [server('linear'), server('notion', { enabled: false })] })

    await setBotAccess(scope, localRef, true, entry('notion'))

    expect(rpc.configureProfileMcp).toHaveBeenCalledWith(scope, ['linear', 'notion'])
    expect(install.installBundledEntry).not.toHaveBeenCalled()
  })

  it('disables a server without touching the others', async () => {
    rpc.listMcpServers.mockResolvedValue({ servers: [server('linear'), server('notion')] })

    await setBotAccess(scope, localRef, false, null)

    expect(rpc.configureProfileMcp).toHaveBeenCalledWith(scope, ['linear'])
  })

  it('installs the catalog entry into the agent profile first when it has none', async () => {
    rpc.listMcpServers
      .mockResolvedValueOnce({ servers: [server('linear')] })
      .mockResolvedValueOnce({ servers: [server('linear'), server('notion', { enabled: false })] })

    await setBotAccess(scope, localRef, true, entry('notion'))

    expect(install.installBundledEntry).toHaveBeenCalledWith(expect.objectContaining({ name: 'notion' }), {}, scope)
    expect(rpc.configureProfileMcp).toHaveBeenCalledWith(scope, ['linear', 'notion'])
  })

  it('never asks for credentials: an app that needs them is reported as needing setup, with nothing written', async () => {
    rpc.listMcpServers.mockResolvedValue({ servers: [] })

    await expect(setBotAccess(scope, localRef, true, entry('notion', true))).rejects.toMatchObject({
      kind: 'needsSetup'
    })

    expect(install.installBundledEntry).not.toHaveBeenCalled()
    expect(rpc.configureProfileMcp).not.toHaveBeenCalled()
  })

  it('reports an app unknown to the catalog as needing setup', async () => {
    rpc.listMcpServers.mockResolvedValue({ servers: [] })

    await expect(setBotAccess(scope, localRef, true, null)).rejects.toBeInstanceOf(BotAppError)
  })

  it('surfaces a save the profile refused instead of reporting success', async () => {
    rpc.listMcpServers.mockResolvedValue({ servers: [server('notion', { enabled: false })] })
    rpc.configureProfileMcp.mockResolvedValue({ applied: { mcp_servers: false }, ok: false })

    await expect(setBotAccess(scope, localRef, true, null)).rejects.toMatchObject({ kind: 'failed' })
  })
})

describe('setBotAccess serialisation', () => {
  const tick = () => new Promise<void>(resolve => setTimeout(resolve, 0))

  const fakeBackend = (initial: Record<string, string[]>) => {
    const enabled = new Map(Object.entries(initial))

    const rows = (key: string) =>
      ['linear', 'notion', 'github'].map(name => server(name, { enabled: (enabled.get(key) ?? []).includes(name) }))

    rpc.listMcpServers.mockImplementation(async (s: { profile: string }) => {
      const snapshot = rows(s.profile)

      await tick()

      return { servers: snapshot }
    })

    rpc.configureProfileMcp.mockImplementation(async (s: { profile: string }, names: string[]) => {
      await tick()
      enabled.set(s.profile, names)

      return { applied: { mcp_servers: true }, ok: true }
    })

    return enabled
  }

  it('lands both toggles when two apps change for the same agent at once', async () => {
    const enabled = fakeBackend({ writer: ['linear'] })

    await Promise.all([
      setBotAccess(scope, { kind: 'local', name: 'notion' }, true, null),
      setBotAccess({ ...scope }, { kind: 'local', name: 'github' }, true, null)
    ])

    expect([...(enabled.get('writer') ?? [])].sort()).toEqual(['github', 'linear', 'notion'])
  })

  it('does not make one agent wait for another', async () => {
    fakeBackend({ writer: [], editor: [] })

    let releaseWriter!: () => void

    rpc.configureProfileMcp.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          releaseWriter = () => resolve({ applied: { mcp_servers: true }, ok: true })
        })
    )

    const writer = setBotAccess(scope, localRef, true, null)
    await tick()
    await tick()

    await setBotAccess({ connectionId: null, profile: 'editor' }, localRef, true, null)
    expect(rpc.configureProfileMcp).toHaveBeenLastCalledWith({ connectionId: null, profile: 'editor' }, ['notion'])

    releaseWriter()
    await writer
  })

  it('keeps the same profile on different connections apart', async () => {
    fakeBackend({ writer: [] })

    let releaseFirst!: () => void

    rpc.configureProfileMcp.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          releaseFirst = () => resolve({ applied: { mcp_servers: true }, ok: true })
        })
    )

    const first = setBotAccess(scope, localRef, true, null)
    await tick()
    await tick()

    await setBotAccess({ connectionId: 'remote-1', profile: 'writer' }, localRef, true, null)

    releaseFirst()
    await first
  })

  it('runs the next change after a failed one', async () => {
    const enabled = fakeBackend({ writer: [] })

    rpc.configureProfileMcp.mockImplementationOnce(async () => ({ applied: { mcp_servers: false }, ok: false }))

    const failing = setBotAccess(scope, { kind: 'local', name: 'notion' }, true, null)
    const following = setBotAccess(scope, { kind: 'local', name: 'github' }, true, null)

    await expect(failing).rejects.toMatchObject({ kind: 'failed' })
    await following

    expect(enabled.get('writer')).toEqual(['github'])
  })

  it('reads the policy revision only once the previous hosted change has landed', async () => {
    let revision = 'rev-1'

    rpc.connectorPolicy.mockImplementation(async () => {
      const seen = revision

      await tick()

      return {
        effective: {},
        layers: [{ body: { mode: 'unrestricted' }, kind: 'member', revision: seen }]
      }
    })

    rpc.setConnectorPolicy.mockImplementation(async (_s: unknown, _op: unknown, expected: string) => {
      await tick()

      if (expected !== revision) {
        throw new Error('stale revision')
      }

      revision = `${revision}+`

      return { revision }
    })

    await Promise.all([
      setBotAccess(scope, { kind: 'hosted', slug: 'gmail' }, false, null),
      setBotAccess(scope, { kind: 'hosted', slug: 'slack' }, false, null)
    ])

    expect(rpc.setConnectorPolicy).toHaveBeenCalledTimes(2)
  })
})

describe('readBotAppsState', () => {
  it('keeps the half that answered when the other fails', async () => {
    rpc.connectorPolicy.mockRejectedValue(new Error('not signed in'))
    rpc.listMcpServers.mockResolvedValue({ servers: [server('notion')] })

    const state = await readBotAppsState({ connectionId: null, profile: 'reader' })

    expect(state.policy).toBeNull()
    expect(state.mcp?.map(row => row.name)).toEqual(['notion'])
  })
})
