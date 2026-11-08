import type * as HermesSdk from '@hermes/plugin-sdk'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { translateBots } from './i18n-test-helper'
import type { BotMeta, RosterRow } from './types'

const { saveBotMeta, notify } = vi.hoisted(() => ({
  saveBotMeta: vi.fn(),
  notify: vi.fn()
}))

vi.mock('@hermes/plugin-sdk', async importOriginal => {
  const sdk = await importOriginal<typeof HermesSdk>()

  return { ...sdk, host: { ...sdk.host, notify }, usePluginI18n: () => translateBots }
})

vi.mock('./shared', () => ({ getPluginCtx: () => null, ID: 'hermes-bots' }))

vi.mock('./data', async importOriginal => ({
  ...(await importOriginal<Record<string, unknown>>()),
  saveBotMeta
}))

const { AvatarPopover } = await import('./avatar-popover')
const { botAppearance } = await import('./avatar')

const owner: RosterRow = { name: 'alpha', title: 'Alpha' }

function open(meta = null as BotMeta | null, bot = 'alpha') {
  render(<AvatarPopover bot={bot} meta={meta} owner={{ ...owner, name: bot }} />)
  fireEvent.click(screen.getByRole('button', { name: 'Change avatar' }))
}

beforeEach(() => {
  saveBotMeta.mockReset()
  saveBotMeta.mockResolvedValue({ serverOutcome: 'persisted' })
  notify.mockReset()
})

afterEach(cleanup)

describe('AvatarPopover', () => {
  it('opens a card with the Bot, Generate and Upload tabs and Reset', () => {
    open()

    expect(screen.getAllByRole('tab').map(tab => tab.textContent)).toEqual(['Bot', 'Generate', 'Upload'])
    expect(screen.getByRole('button', { name: 'Reset' })).toBeTruthy()
  })

  it('offers every silhouette and saves the chosen one at once', () => {
    open()

    expect(screen.getAllByRole('radio', { name: /^Shape \d+$/ })).toHaveLength(14)

    fireEvent.click(screen.getByRole('radio', { name: 'Shape 4' }))

    expect(saveBotMeta).toHaveBeenCalledWith(
      owner,
      expect.objectContaining({ shape: 'blobatar::capsule', image: null, custom: true })
    )
  })

  it('keeps a pinned seed when another silhouette is chosen', () => {
    open({ shape: 'blobatar:abc123:round', custom: true })

    fireEvent.click(screen.getByRole('radio', { name: 'Shape 9' }))

    expect(saveBotMeta).toHaveBeenCalledWith(owner, expect.objectContaining({ shape: 'blobatar:abc123:sun' }))
  })

  it('offers eighteen colours in three rows of six', () => {
    open()

    const swatches = screen.getAllByRole('radio', { name: /^Color \d+$/ })

    expect(swatches).toHaveLength(18)
    expect(screen.getAllByRole('radiogroup')[1]!.className).toContain('grid-cols-6')
  })

  it.each([
    [1, '#f5f5f5'],
    [18, '#3a3a3a']
  ])('saves colour %i as %s at once', (position, hex) => {
    open()

    fireEvent.click(screen.getByRole('radio', { name: `Color ${position}` }))

    expect(saveBotMeta).toHaveBeenCalledWith(owner, expect.objectContaining({ color: hex, image: null, custom: true }))
  })

  it.each(['alpha', 'default'])('returns %s to the look of a never-customised bot on Reset', bot => {
    const customised: BotMeta = {
      shape: 'blobatar::sun',
      color: '#e84545',
      custom: true,
      image: null,
      imageKind: 'shape'
    }

    open(customised, bot)
    fireEvent.click(screen.getByRole('button', { name: 'Reset' }))

    const patch = saveBotMeta.mock.calls[0]![1] as Record<string, unknown>

    expect(patch.custom).toBe(false)
    expect(botAppearance(bot, { ...customised, ...patch })).toEqual(botAppearance(bot, null))
  })

  it('tells the user when the save only reached this machine', async () => {
    saveBotMeta.mockResolvedValue({ serverOutcome: 'failed' })
    open()

    fireEvent.click(screen.getByRole('radio', { name: 'Shape 3' }))
    await vi.waitFor(() => expect(notify).toHaveBeenCalledWith({ kind: 'error', message: translateBots('avatar.savedLocally') }))
  })

  it('closes on Escape', () => {
    open()
    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' })

    expect(screen.queryByRole('tab', { name: 'Bot' })).toBeNull()
  })

  describe('rapid picks', () => {
    interface Pending {
      reject: (error: unknown) => void
      resolve: (value: unknown) => void
    }

    function slowSaves() {
      const pending: Pending[] = []
      const landed: Record<string, unknown>[] = []

      saveBotMeta.mockImplementation((_owner: unknown, patch: Record<string, unknown>) => {
        landed.push(patch)

        return new Promise((resolve, reject) => pending.push({ resolve, reject }))
      })

      return { pending, landed }
    }

    const settle = () => new Promise(resolve => setTimeout(resolve, 0))

    it('shows each pick at once but saves one at a time, ending on the last pick', async () => {
      const { pending, landed } = slowSaves()

      open()
      fireEvent.click(screen.getByRole('radio', { name: 'Shape 2' }))
      fireEvent.click(screen.getByRole('radio', { name: 'Shape 5' }))
      fireEvent.click(screen.getByRole('radio', { name: 'Shape 7' }))

      expect(screen.getByRole('radio', { name: 'Shape 7' }).getAttribute('aria-checked')).toBe('true')
      expect(saveBotMeta).toHaveBeenCalledTimes(1)

      pending[0]!.resolve({ serverOutcome: 'persisted' })
      await vi.waitFor(() => expect(saveBotMeta).toHaveBeenCalledTimes(2))

      pending[1]!.resolve({ serverOutcome: 'persisted' })
      await settle()

      expect(landed.at(-1)).toMatchObject({ shape: 'blobatar::droplet' })
      expect(notify).not.toHaveBeenCalled()
    })

    it('stays quiet when a superseded save fails and only the last failure toasts', async () => {
      const { pending } = slowSaves()

      open()
      fireEvent.click(screen.getByRole('radio', { name: 'Shape 2' }))
      fireEvent.click(screen.getByRole('radio', { name: 'Shape 5' }))

      pending[0]!.resolve({ serverOutcome: 'failed' })
      await vi.waitFor(() => expect(saveBotMeta).toHaveBeenCalledTimes(2))
      expect(notify).not.toHaveBeenCalled()

      pending[1]!.resolve({ serverOutcome: 'failed' })
      await vi.waitFor(() => expect(notify).toHaveBeenCalledTimes(1))
      expect(notify).toHaveBeenCalledWith({ kind: 'error', message: translateBots('avatar.savedLocally') })
    })
  })

  describe('accessibility', () => {
    it('labels shapes and colours with localized positions, never raw ids', () => {
      open()

      const labels = [...screen.getAllByRole('radio')].map(radio => radio.getAttribute('aria-label') ?? '')

      expect(labels.length).toBeGreaterThan(10)

      for (const label of labels) {
        expect(label).toMatch(/^(Shape|Color) \d+$/)
      }
    })

    it('wires tabs to a tabpanel and exposes selection', () => {
      open()

      const tab = screen.getByRole('tab', { name: 'Bot' })
      const panel = screen.getByRole('tabpanel')

      expect(tab.getAttribute('aria-selected')).toBe('true')
      expect(tab.getAttribute('aria-controls')).toBe(panel.id)
      expect(panel.getAttribute('aria-labelledby')).toBe(tab.id)
      expect(screen.getByRole('tab', { name: 'Generate' }).getAttribute('aria-selected')).toBe('false')
    })

    it('groups shapes and colours as radiogroups with one tab stop each', () => {
      open()

      const groups = screen.getAllByRole('radiogroup')

      expect(groups).toHaveLength(2)

      for (const group of groups) {
        const stops = [...group.querySelectorAll('[role="radio"]')].filter(radio => radio.getAttribute('tabindex') === '0')

        expect(stops).toHaveLength(1)
      }
    })

    it('moves focus between options with the arrow keys', () => {
      open()

      const first = screen.getByRole('radio', { name: 'Shape 1' })

      first.focus()
      fireEvent.keyDown(first, { key: 'ArrowRight' })
      expect(window.document.activeElement).toBe(screen.getByRole('radio', { name: 'Shape 2' }))

      fireEvent.keyDown(window.document.activeElement!, { key: 'End' })
      expect(window.document.activeElement).toBe(screen.getByRole('radio', { name: 'Shape 14' }))

      fireEvent.keyDown(window.document.activeElement!, { key: 'ArrowRight' })
      expect(window.document.activeElement).toBe(screen.getByRole('radio', { name: 'Shape 1' }))

      fireEvent.keyDown(window.document.activeElement!, { key: 'ArrowLeft' })
      expect(window.document.activeElement).toBe(screen.getByRole('radio', { name: 'Shape 14' }))
    })
  })
})
