/**
 * Share → Export template… on a bot row: the template bytes come from the bot's own gateway and
 * land in the file the owner picks. A cancelled dialog is silent; an older gateway is named.
 */

import type * as HermesSdk from '@hermes/plugin-sdk'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'

import { translateBots } from './i18n-test-helper'

beforeAll(() => {
  Element.prototype.scrollIntoView = vi.fn()
  Element.prototype.hasPointerCapture = vi.fn(() => false)
  Element.prototype.releasePointerCapture = vi.fn()
})

const { notify, notifyError, request } = vi.hoisted(() => ({
  notify: vi.fn(),
  notifyError: vi.fn(),
  request: vi.fn<(method: string, params?: Record<string, unknown>) => Promise<unknown>>()
}))

vi.mock('@hermes/plugin-sdk', async importOriginal => {
  const sdk = await importOriginal<typeof HermesSdk>()

  return { ...sdk, host: { ...sdk.host, notify, notifyError, request }, usePluginI18n: () => translateBots }
})

const { runBotTemplateExport, BotShareSubmenu } = await import('./bot-template-export')
const { ContextMenu, ContextMenuContent, ContextMenuTrigger } = await import('@hermes/plugin-sdk')

const rpcError = (code: number) => Object.assign(new Error('rpc'), { code })
const bot = { name: 'scout', title: 'Scout' }
let saveBotTemplate: ReturnType<typeof vi.fn>

beforeEach(() => {
  vi.clearAllMocks()
  saveBotTemplate = vi.fn()
  Object.assign(window, { hermesDesktop: { saveBotTemplate } })
})

afterEach(() => {
  cleanup()
  delete (window as { hermesDesktop?: unknown }).hermesDesktop
})

describe('runBotTemplateExport', () => {
  it('confirms a saved template by the bot’s name', async () => {
    request.mockResolvedValue({ data: 'QUJD', filename: 'scout.hermesbot' })
    saveBotTemplate.mockResolvedValue({ path: '/x/scout.hermesbot', saved: true })

    await runBotTemplateExport(bot)

    expect(notify).toHaveBeenCalledWith({ kind: 'success', message: 'Exported “Scout” as a template' })
  })

  it('stays quiet when the owner cancels the dialog', async () => {
    request.mockResolvedValue({ data: 'QUJD', filename: 'scout.hermesbot' })
    saveBotTemplate.mockResolvedValue({ canceled: true, saved: false })

    await runBotTemplateExport(bot)

    expect(notify).not.toHaveBeenCalled()
    expect(notifyError).not.toHaveBeenCalled()
  })

  it('tells the owner to update an older gateway', async () => {
    request.mockRejectedValue(rpcError(-32601))

    await runBotTemplateExport(bot)

    expect(notify).toHaveBeenCalledWith({
      kind: 'error',
      message: 'Update Hermes on this bot’s machine to export templates.'
    })
  })

  it('reports any other failure with the reason', async () => {
    const failure = rpcError(5071)
    request.mockRejectedValue(failure)

    await runBotTemplateExport(bot)

    expect(notifyError).toHaveBeenCalledWith(failure, 'Could not export this bot')
  })
})

describe('BotShareSubmenu', () => {
  it('offers Export template… under Share and runs the export', async () => {
    request.mockResolvedValue({ data: 'QUJD', filename: 'scout.hermesbot' })
    saveBotTemplate.mockResolvedValue({ saved: true })
    render(
      <ContextMenu>
        <ContextMenuTrigger>row</ContextMenuTrigger>
        <ContextMenuContent>
          <BotShareSubmenu bot={bot} />
        </ContextMenuContent>
      </ContextMenu>
    )

    fireEvent.contextMenu(screen.getByText('row'))
    const trigger = await screen.findByText('Share')
    fireEvent.keyDown(trigger, { key: 'ArrowRight' })
    fireEvent.click(await screen.findByText('Export template…'))

    await waitFor(() => expect(request).toHaveBeenCalledWith('profiles.template.export', { name: 'scout' }))
  })
})
