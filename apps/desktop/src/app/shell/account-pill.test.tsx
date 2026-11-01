import { fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { afterEach, describe, expect, it, vi } from 'vitest'

import { $botChromeless } from '@/store/bot-surface'

import { AccountPill } from './account-pill'

vi.mock('@/app/chat/sidebar/connection-switcher', async importOriginal => ({
  ...(await importOriginal<object>()),
  useConnectionSwitch: () => ({ activeConnectionId: 'local', choose: vi.fn(), connections: [], dialog: null })
}))

function renderPill(props: Parameters<typeof AccountPill>[0] = {}) {
  $botChromeless.set(true)

  return render(
    <MemoryRouter>
      <AccountPill {...props} />
    </MemoryRouter>
  )
}

afterEach(() => $botChromeless.set(false))

describe('AccountPill footer', () => {
  it('shows the initials disc and the full name', () => {
    renderPill({ displayName: 'Huy Dinh' })

    const pill = screen.getByRole('button', { name: /Huy Dinh/ })

    expect(pill.textContent).toContain('HD')
    expect(pill.textContent).toContain('Huy Dinh')
  })

  it('opens Connect apps from the apps button', () => {
    const onOpenApps = vi.fn()

    renderPill({ appsLabel: 'Connect apps', displayName: 'Huy Dinh', onOpenApps })
    fireEvent.click(screen.getByRole('button', { name: 'Connect apps' }))

    expect(onOpenApps).toHaveBeenCalledTimes(1)
  })

  it('renders nothing outside Bot Mode', () => {
    $botChromeless.set(false)

    const { container } = render(
      <MemoryRouter>
        <AccountPill displayName="Huy Dinh" />
      </MemoryRouter>
    )

    expect(container.firstChild).toBeNull()
  })
})
