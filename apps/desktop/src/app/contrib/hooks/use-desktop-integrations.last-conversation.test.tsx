import { renderHook, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { DesktopConnectionsRegistry, HermesConnection } from '@/global'
import { $connectionsRegistry } from '@/store/connection-registry-state'
import { $lastConversation, rememberLastConversation } from '@/store/last-conversation'
import { type BotChatRestorer, registerBotChatRestorer } from '@/store/last-conversation-restore'
import {
  $connection,
  _resetLegacyDiscardForTests,
  _resetSessionOwnerHintsForTests,
  getRememberedRoute,
  getSessionOwnerHints,
  setRememberedRoute,
  setRememberedSessionId,
  setSessionOwnerHint
} from '@/store/session'
import type * as WindowsStore from '@/store/windows'

import { makeSessionInfo } from '../../../test/session-info'

import { useDesktopIntegrations } from './use-desktop-integrations'

const { peerWindowMock } = vi.hoisted(() => ({ peerWindowMock: vi.fn(() => false) }))

vi.mock('@/store/windows', async importOriginal => ({
  ...(await importOriginal<typeof WindowsStore>()),
  isPeerInstanceWindow: () => peerWindowMock()
}))

const registry = (...ids: string[]) =>
  ({
    connections: ids.map(id => ({ id, kind: id === 'local' ? 'local' : 'ssh', label: id })),
    primary: ids[0],
    secureTokenStorage: true,
    version: 2
  }) as unknown as DesktopConnectionsRegistry

interface MountOptions {
  locationPathname?: string
  resumeLastSession?: boolean
  routedSessionId?: null | string
}

describe('reopen the last conversation on launch', () => {
  let navigate: ReturnType<typeof vi.fn<(to: string, options?: { replace?: boolean }) => void>>
  let restorer: ReturnType<typeof vi.fn<BotChatRestorer>>
  let unregister: () => void

  function mount({ locationPathname = '/', resumeLastSession = true, routedSessionId = null }: MountOptions = {}) {
    return renderHook(
      ({ sessions }: { sessions: ReturnType<typeof makeSessionInfo>[] }) =>
        useDesktopIntegrations({
          activeProfile: 'default',
          chatOpen: false,
          hasPreview: false,
          locationPathname,
          navigate,
          profileReady: true,
          refreshSessions: vi.fn(),
          resumeExhaustedSessionId: null,
          resumeLastSession,
          routedSessionId,
          runtimeIdByStoredSessionId: { current: new Map() },
          sessions
        }),
      { initialProps: { sessions: [makeSessionInfo({ id: 'sess-1' })] } }
    )
  }

  beforeEach(() => {
    window.localStorage.clear()
    window.location.hash = '#/'
    _resetLegacyDiscardForTests()
    peerWindowMock.mockReturnValue(false)
    navigate = vi.fn()
    restorer = vi.fn<BotChatRestorer>(async () => ({ connectionId: 'pi', profile: 'chief', status: 'opened' }))
    unregister = registerBotChatRestorer(restorer)
    $lastConversation.set(null)
    $connectionsRegistry.set(registry('local', 'pi'))
    vi.spyOn(console, 'warn').mockImplementation(() => undefined)
  })

  afterEach(() => {
    unregister()
    $connection.set(null)
    $connectionsRegistry.set(null)
    vi.restoreAllMocks()
  })

  it('reopens the remembered Bot Chat instead of the home screen', async () => {
    rememberLastConversation({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief' })

    mount()

    await waitFor(() => expect(restorer).toHaveBeenCalledTimes(1))
    expect(restorer.mock.calls[0]![0]).toEqual({ connectionId: 'pi', kind: 'bot', profile: 'chief' })
  })

  it('the Bot Chat wins over an older remembered normal session', async () => {
    setRememberedSessionId('sess-1', 'default')
    setRememberedRoute('/sess-1', 'default')
    rememberLastConversation({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief' })

    mount()

    await waitFor(() => expect(restorer).toHaveBeenCalled())
    expect(navigate).not.toHaveBeenCalled()
  })

  it('a window reload restores again from the persisted pointer', async () => {
    rememberLastConversation({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief' })

    const first = mount()

    await waitFor(() => expect(restorer).toHaveBeenCalledTimes(1))
    first.unmount()

    mount()

    await waitFor(() => expect(restorer).toHaveBeenCalledTimes(2))
  })

  it('falls back to the primary Bot Chat when the remembered connection is gone, without an error', async () => {
    rememberLastConversation({ connectionId: 'hermes-tsnanh-dev', kind: 'bot-chat', profile: 'chief' })
    restorer.mockResolvedValue({ connectionId: 'pi', profile: 'faker-kit', status: 'opened' })

    mount()

    await waitFor(() => expect(restorer).toHaveBeenCalledTimes(1))
    expect(restorer.mock.calls[0]![0]).toEqual({ kind: 'primary-most-recent' })
    await waitFor(() => expect($lastConversation.get()).toMatchObject({ connectionId: 'pi', profile: 'faker-kit' }))
    expect(console.warn).not.toHaveBeenCalled()
  })

  it('clears a stale pointer and stays home when no Bot Chat can replace it', async () => {
    rememberLastConversation({ connectionId: 'hermes-tsnanh-dev', kind: 'bot-chat', profile: 'chief' })
    restorer.mockResolvedValue({ status: 'missing' })

    mount()

    await waitFor(() => expect($lastConversation.get()).toBeNull())
    expect(navigate).not.toHaveBeenCalled()
  })

  it('an explicit navigation during boot wins over the restore', async () => {
    rememberLastConversation({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief' })

    mount({ locationPathname: '/settings' })

    await new Promise(resolve => setTimeout(resolve, 20))
    expect(restorer).not.toHaveBeenCalled()
  })

  it('a navigation made between launch and the first attempt wins', async () => {
    rememberLastConversation({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief' })
    $connectionsRegistry.set(null)

    mount()

    window.location.hash = '#/capabilities'
    $connectionsRegistry.set(registry('local', 'pi'))

    await new Promise(resolve => setTimeout(resolve, 20))
    expect(restorer).not.toHaveBeenCalled()
  })

  it('does nothing when resuming the last session is switched off', async () => {
    rememberLastConversation({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief' })

    mount({ resumeLastSession: false })

    await new Promise(resolve => setTimeout(resolve, 20))
    expect(restorer).not.toHaveBeenCalled()
  })

  it('a peer window keeps its own fresh draft', async () => {
    peerWindowMock.mockReturnValue(true)
    rememberLastConversation({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief' })

    mount()

    await new Promise(resolve => setTimeout(resolve, 20))
    expect(restorer).not.toHaveBeenCalled()
  })

  it('leaves a remembered normal session on a live connection to the session restore', async () => {
    setRememberedSessionId('sess-1', 'default')
    setRememberedRoute('/sess-1', 'default')
    rememberLastConversation({ connectionId: 'pi', kind: 'session', profile: 'default', sessionId: 'sess-1' })

    mount()

    await waitFor(() => expect(navigate).toHaveBeenCalledWith('/sess-1', { replace: true }))
    expect(restorer).not.toHaveBeenCalled()
  })

  it('a sessions refresh with a background routed session never rewrites the pointer', async () => {
    rememberLastConversation({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief' })
    unregister()
    $connection.set({ connectionId: 'pi', mode: 'remote', wsUrl: 'wss://pi.example/api/ws' } as HermesConnection)

    const view = mount({ locationPathname: '/sess-1', routedSessionId: 'sess-1' })
    const before = $lastConversation.get()

    view.rerender({ sessions: [makeSessionInfo({ id: 'sess-1' }), makeSessionInfo({ id: 'sess-2' })] })
    view.rerender({ sessions: [makeSessionInfo({ id: 'sess-1' })] })

    expect($lastConversation.get()).toBe(before)
    expect($lastConversation.get()).toMatchObject({ kind: 'bot-chat', profile: 'chief' })
  })

  describe('without a Bot Mode restorer', () => {
    beforeEach(() => {
      vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] })
      unregister()
    })

    afterEach(() => {
      vi.useRealTimers()
    })

    it('holds the legacy session restore through the grace period, then releases it and keeps the pointer', async () => {
      setRememberedSessionId('sess-1', 'default')
      setRememberedRoute('/sess-1', 'default')
      rememberLastConversation({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief' })

      mount()

      await vi.advanceTimersByTimeAsync(4_000)
      expect(navigate).not.toHaveBeenCalled()

      await vi.advanceTimersByTimeAsync(2_500)
      expect(navigate).toHaveBeenCalledWith('/sess-1', { replace: true })
      expect($lastConversation.get()).toMatchObject({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief' })
    })
  })

  it('a restore that opened the bot does not overwrite the remembered route with the home route', async () => {
    setRememberedRoute('/skills', 'default')
    rememberLastConversation({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief' })

    mount()

    await waitFor(() => expect(restorer).toHaveBeenCalledTimes(1))
    await new Promise(resolve => setTimeout(resolve, 20))

    expect(getRememberedRoute('default')).toBe('/skills')
  })

  describe('owner hints against the connection registry', () => {
    const degraded = (...ids: string[]) => ({ ...registry(...ids), degraded: true }) as DesktopConnectionsRegistry

    const quarantined = (...ids: string[]) =>
      ({ ...registry(...ids), quarantined: [{ label: 'broken', reason: 'malformed' }] }) as DesktopConnectionsRegistry

    beforeEach(() => {
      _resetSessionOwnerHintsForTests({ storage: true })
      setSessionOwnerHint('remote-session', { connectionId: 'vps', profile: 'chief' })
    })

    it('prunes hints for a connection a complete registry no longer has', () => {
      mount()

      expect(getSessionOwnerHints('remote-session')).toEqual([])
    })

    it('keeps them while the registry is the degraded local-only fallback', () => {
      $connectionsRegistry.set(degraded('local'))

      mount()

      expect(getSessionOwnerHints('remote-session')).toHaveLength(1)
    })

    it('keeps them while the registry has quarantined entries', () => {
      $connectionsRegistry.set(quarantined('local'))

      mount()

      expect(getSessionOwnerHints('remote-session')).toHaveLength(1)
    })
  })
})
