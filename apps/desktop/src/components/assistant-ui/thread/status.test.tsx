import { act, cleanup, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { __resetElapsedTimerRegistryForTests } from '@/components/chat/activity-timer'
import { I18nProvider } from '@/i18n'
import { type ChatPersona, ChatPersonaContext } from '@/store/chat-persona'
import { $providerWaitSessions, setSessionProviderWait } from '@/store/provider-wait'
import { $activeSessionId, $turnStartedAt } from '@/store/session'

import { ResponseLoadingIndicator } from './status'

const PERSONA: ChatPersona = { avatar: () => null, name: 'Bot' }

function renderIndicator(persona: ChatPersona | null = null) {
  return render(
    <I18nProvider configClient={null} initialLocale="en">
      <ChatPersonaContext.Provider value={persona}>
        <ResponseLoadingIndicator />
      </ChatPersonaContext.Provider>
    </I18nProvider>
  )
}

describe('ResponseLoadingIndicator timer', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-01-01T00:00:00.000Z'))
    // useViewedInterval gates ticking on document focus + visibility; jsdom's
    // hasFocus() is unreliable across runners, so pin it (same as the
    // background-sync backstop tests).
    vi.spyOn(globalThis.document, 'hasFocus').mockReturnValue(true)
    __resetElapsedTimerRegistryForTests()
  })

  afterEach(() => {
    cleanup()
    $activeSessionId.set(null)
    $turnStartedAt.set(null)
    $providerWaitSessions.set({})
    __resetElapsedTimerRegistryForTests()
    vi.restoreAllMocks()
    vi.useRealTimers()
  })

  it('preserves each running session timer while switching between sessions', () => {
    $activeSessionId.set('session-a')
    $turnStartedAt.set(Date.now())
    const sessionA = renderIndicator()

    act(() => vi.advanceTimersByTime(5_000))
    expect(screen.getAllByText((_, node) => node?.textContent === '5s').length).toBeGreaterThan(0)
    sessionA.unmount()

    $activeSessionId.set('session-b')
    $turnStartedAt.set(Date.now())
    const sessionB = renderIndicator()

    act(() => vi.advanceTimersByTime(3_000))
    expect(screen.getAllByText((_, node) => node?.textContent === '3s').length).toBeGreaterThan(0)
    sessionB.unmount()

    $activeSessionId.set('session-a')
    $turnStartedAt.set(new Date('2026-01-01T00:00:00.000Z').getTime())
    renderIndicator()

    expect(screen.getAllByText((_, node) => node?.textContent === '8s').length).toBeGreaterThan(0)
  })

  it('names a prolonged provider wait in the existing response status row', () => {
    $activeSessionId.set('session-a')
    $turnStartedAt.set(Date.now())
    setSessionProviderWait('session-a', '⏳ waiting on local-model — 30s with no output yet')

    renderIndicator()

    expect(screen.getByText('⏳ waiting on local-model — 30s with no output yet')).toBeTruthy()
  })

  it('keeps the ticking timer out of the live region accessibility tree', () => {
    $activeSessionId.set('session-a')
    $turnStartedAt.set(Date.now())
    renderIndicator()

    act(() => vi.advanceTimersByTime(2_000))

    const status = screen.getByRole('status')
    const timer = [...status.querySelectorAll('[aria-hidden="true"]')].find(el => el.textContent === '2s')

    expect(status.getAttribute('aria-live')).toBe('polite')
    expect(timer).toBeDefined()
  })

  it('shows one shimmering working label with no timer or pulse in a bot chat', () => {
    $activeSessionId.set('session-a')
    $turnStartedAt.set(Date.now())
    const { container } = renderIndicator(PERSONA)

    act(() => vi.advanceTimersByTime(5_000))

    const label = screen.getByText('Reviewing your request')

    expect(label.className).toContain('shimmer')
    expect(screen.getByRole('status').getAttribute('aria-label')).toBe('Reviewing your request')
    expect(screen.queryByText((_, node) => node?.textContent === '5s')).toBeNull()
    expect(container.querySelector('.dither')).toBeNull()
  })

  it('keeps the pulse and timer outside a bot chat', () => {
    $activeSessionId.set('session-a')
    $turnStartedAt.set(Date.now())
    const { container } = renderIndicator()

    act(() => vi.advanceTimersByTime(5_000))

    expect(screen.queryByText('Reviewing your request')).toBeNull()
    expect(screen.getAllByText((_, node) => node?.textContent === '5s').length).toBeGreaterThan(0)
    expect(container.querySelector('.dither')).not.toBeNull()
  })

  it('names a provider wait instead of the generic label in a bot chat', () => {
    $activeSessionId.set('session-a')
    $turnStartedAt.set(Date.now())
    setSessionProviderWait('session-a', '⏳ waiting on local-model — 30s with no output yet')

    renderIndicator(PERSONA)

    expect(screen.getByText('⏳ waiting on local-model — 30s with no output yet')).toBeTruthy()
    expect(screen.queryByText('Reviewing your request')).toBeNull()
  })
})
