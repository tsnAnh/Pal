/**
 * "About you": the owner facts every bot shares. The menu entry only appears on a gateway that
 * knows the RPC; the form walks loading → ready → saved, and failures stay in the dialog with a
 * way forward.
 */

import type * as HermesSdk from '@hermes/plugin-sdk'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'

import { translateBots } from './i18n-test-helper'

beforeAll(() => {
  Element.prototype.scrollIntoView = vi.fn()
  Element.prototype.hasPointerCapture = vi.fn(() => false)
  Element.prototype.releasePointerCapture = vi.fn()
})

const { request } = vi.hoisted(() => ({
  request: vi.fn<(method: string, params?: Record<string, unknown>) => Promise<unknown>>()
}))

vi.mock('@hermes/plugin-sdk', async importOriginal => {
  const sdk = await importOriginal<typeof HermesSdk>()

  return {
    ...sdk,
    host: {
      ...sdk.host,
      request,
      state: {
        ...sdk.host.state,
        connectionId: sdk.atom<string | null>('local'),
        gateway: sdk.atom('open'),
        profile: sdk.atom('default')
      }
    },
    usePluginI18n: () => translateBots
  }
})

const { $aboutYouOpen, closeAboutYou, openAboutYou } = await import('./about-you')
const { AboutYouDialog, AboutYouMenuItem } = await import('./about-you-dialog')
const { DropdownMenu, DropdownMenuContent } = await import('@hermes/plugin-sdk')

const rpcError = (code: number) => Object.assign(new Error('rpc'), { code })

function answer(facts: { name: string; timezone: string }) {
  request.mockImplementation(async method => (method === 'bot_mode.about_you.get' ? facts : {}))
}

beforeEach(() => {
  request.mockReset()
  closeAboutYou()
  vi.spyOn(Intl, 'DateTimeFormat').mockImplementation(
    () => ({ resolvedOptions: () => ({ timeZone: 'Asia/Tokyo' }) }) as unknown as Intl.DateTimeFormat
  )
})

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('AboutYouDialog', () => {
  it('prefills the saved facts and saves the trimmed name with the stored zone', async () => {
    answer({ name: 'Ann', timezone: 'Europe/Paris' })
    request.mockImplementation(async method =>
      method === 'bot_mode.about_you.get' ? { name: 'Ann', timezone: 'Europe/Paris' } : { name: 'Bea', timezone: 'Europe/Paris' }
    )
    render(<AboutYouDialog />)
    act(() => openAboutYou())

    const input = (await screen.findByLabelText('Your name')) as HTMLInputElement
    expect(input.value).toBe('Ann')
    expect(screen.getByRole('combobox').textContent).toContain('Europe/Paris')

    fireEvent.change(input, { target: { value: '  Bea  ' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))

    await waitFor(() => expect(request).toHaveBeenCalledWith('bot_mode.about_you.set', { name: 'Bea', timezone: 'Europe/Paris' }))
    await waitFor(() => expect($aboutYouOpen.get()).toBe(false))
  })

  it('defaults an empty time zone to Auto-detect and saves the browser zone', async () => {
    answer({ name: '', timezone: '' })
    render(<AboutYouDialog />)
    act(() => openAboutYou())

    await screen.findByLabelText('Your name')
    expect(screen.getByRole('combobox').textContent).toContain('Auto-detect (Asia/Tokyo)')

    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(request).toHaveBeenCalledWith('bot_mode.about_you.set', { name: '', timezone: 'Asia/Tokyo' }))
  })

  it('shows loading, then a retry when the facts cannot be loaded', async () => {
    request.mockRejectedValueOnce(rpcError(5000))
    render(<AboutYouDialog />)
    act(() => openAboutYou())

    expect(screen.getByText('Loading…')).toBeTruthy()
    expect(await screen.findByText('Couldn’t load your details.')).toBeTruthy()
    expect((screen.getByRole('button', { name: 'Save' }) as HTMLButtonElement).disabled).toBe(true)

    answer({ name: 'Ann', timezone: '' })
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(((await screen.findByLabelText('Your name')) as HTMLInputElement).value).toBe('Ann')
  })

  it('keeps the dialog open with a specific message for an unrecognized time zone', async () => {
    request.mockImplementation(async method => {
      if (method === 'bot_mode.about_you.get') {
        return { name: '', timezone: '' }
      }

      throw rpcError(4065)
    })
    render(<AboutYouDialog />)
    act(() => openAboutYou())
    await screen.findByLabelText('Your name')

    fireEvent.click(screen.getByRole('button', { name: 'Save' }))

    expect((await screen.findByRole('alert')).textContent).toBe('That time zone isn’t recognized.')
    expect($aboutYouOpen.get()).toBe(true)
  })

  it('keeps the dialog open with a generic message when the save fails', async () => {
    request.mockImplementation(async method => {
      if (method === 'bot_mode.about_you.get') {
        return { name: '', timezone: '' }
      }

      throw rpcError(5067)
    })
    render(<AboutYouDialog />)
    act(() => openAboutYou())
    await screen.findByLabelText('Your name')

    fireEvent.click(screen.getByRole('button', { name: 'Save' }))

    expect((await screen.findByRole('alert')).textContent).toBe('Couldn’t save your details. Try again.')
    expect($aboutYouOpen.get()).toBe(true)
  })
})

describe('AboutYouMenuItem', () => {
  const renderItem = () =>
    render(
      <DropdownMenu open>
        <DropdownMenuContent>
          <AboutYouMenuItem />
        </DropdownMenuContent>
      </DropdownMenu>
    )

  it('is offered once the gateway answers the facts call', async () => {
    answer({ name: '', timezone: '' })
    renderItem()

    expect(await screen.findByText('About you…')).toBeTruthy()
  })

  it('is hidden on a gateway that predates the RPC', async () => {
    request.mockRejectedValue(rpcError(-32601))
    renderItem()

    await waitFor(() => expect(request).toHaveBeenCalled())
    await act(async () => undefined)
    expect(screen.queryByText('About you…')).toBeNull()
  })

  it('stays offered when the check fails for another reason', async () => {
    request.mockRejectedValue(rpcError(5000))
    renderItem()

    expect(await screen.findByText('About you…')).toBeTruthy()
  })
})
