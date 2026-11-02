import { beforeEach, describe, expect, it, vi } from 'vitest'

const { hostMock, requestForBotMock } = vi.hoisted(() => ({
  hostMock: { openSession: vi.fn(), request: vi.fn() },
  requestForBotMock: vi.fn()
}))

vi.mock('@hermes/plugin-sdk', () => ({
  BOT_CHAT_SESSION_HYDRATION_TIMEOUT_MS: 15_000,
  host: hostMock
}))

vi.mock('./routing', () => ({
  backendTargetProfile: (route: { targetProfile?: string } | null, name: string) => route?.targetProfile ?? name,
  botConnectionRoute: () => null,
  botRosterMeta: () => ({}),
  botWorkspaceOwnerKey: (bot: { name?: string } | null) => `bot:${bot?.name || 'default'}`,
  requestForBot: requestForBotMock
}))

vi.mock('./data', () => ({
  $botMeta: { get: () => ({}), set: vi.fn() },
  botMetaKey: (bot: { name?: string }) => bot?.name ?? '',
  botOwner: (owner: { name?: string } | string) =>
    typeof owner === 'string'
      ? { bot: { name: owner }, key: owner, name: owner, route: null }
      : { bot: owner, key: owner?.name, name: owner?.name, route: null },
  persistBotMetaSnapshot: vi.fn(),
  saveBotMeta: vi.fn()
}))

vi.mock('./shared', () => ({ getPluginCtx: () => null }))

function respondWith(handler: (method: string) => unknown) {
  const methods: string[] = []

  requestForBotMock.mockImplementation(async (_bot: unknown, method: string) => {
    methods.push(method)

    return handler(method)
  })

  return methods
}

async function loadModule() {
  vi.resetModules()

  return import('./canonical-chat')
}

beforeEach(() => {
  vi.clearAllMocks()
  hostMock.openSession.mockResolvedValue(undefined)
})

describe('openBotCanonicalChat with createIfMissing:false', () => {
  it('returns null and never creates a session when the profile has no Bot Chat', async () => {
    const methods = respondWith(method => (method === 'session.list' ? { sessions: [] } : {}))
    const { openBotCanonicalChat } = await loadModule()

    await expect(openBotCanonicalChat('ops', { createIfMissing: false })).resolves.toBeNull()

    expect(methods).toEqual(['session.list'])
    expect(methods).not.toContain('session.create')
    expect(hostMock.openSession).not.toHaveBeenCalled()
  })

  it('still opens an existing Bot Chat', async () => {
    respondWith(method =>
      method === 'session.list' ? { sessions: [{ id: 'root', resolved_id: 'tip', title: 'Bot Chat' }] } : {}
    )

    const { openBotCanonicalChat } = await loadModule()

    await expect(openBotCanonicalChat('ops', { createIfMissing: false })).resolves.toEqual({
      openedId: 'tip',
      registryId: 'root'
    })
    expect(hostMock.openSession).toHaveBeenCalledTimes(1)
  })

  it('does not open anything when the owner moved on during the slow lookup', async () => {
    let current = true

    respondWith(method => {
      current = false

      return method === 'session.list' ? { sessions: [{ id: 'root', title: 'Bot Chat' }] } : {}
    })

    const { openBotCanonicalChat } = await loadModule()

    await expect(
      openBotCanonicalChat('ops', { createIfMissing: false, openingStillCurrent: () => current })
    ).resolves.toBeNull()
    expect(hostMock.openSession).not.toHaveBeenCalled()
  })

  it('a throwing lookup propagates so the restore can retry, and still creates nothing', async () => {
    const methods = respondWith(() => {
      throw new Error('backend restarting')
    })

    const { openBotCanonicalChat } = await loadModule()

    await expect(openBotCanonicalChat('ops', { createIfMissing: false })).rejects.toThrow()
    expect(methods).not.toContain('session.create')
  })
})
