/**
 * Importing a bot from a template: the owner reads what the template carries (instructions, tools,
 * MCP servers, routines) before anything is created, then commits exactly what was reviewed.
 * Failures stay in the dialog with a way forward; the entry only exists on gateways that know it.
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

const { createCanonicalChat, notify, request } = vi.hoisted(() => ({
  createCanonicalChat: vi.fn(async () => 'sid-1'),
  notify: vi.fn(),
  request: vi.fn<(method: string, params?: Record<string, unknown>) => Promise<unknown>>()
}))

vi.mock('@hermes/plugin-sdk', async importOriginal => {
  const sdk = await importOriginal<typeof HermesSdk>()

  return {
    ...sdk,
    host: {
      ...sdk.host,
      notify,
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

vi.mock('./canonical-chat', () => ({ createCanonicalChat }))

const { $botTemplateFile, closeBotTemplateImport } = await import('./bot-template')
const { BotTemplateImportDialog, BotTemplateImportMenuItem } = await import('./bot-template-dialog')
const { DropdownMenu, DropdownMenuContent } = await import('@hermes/plugin-sdk')

const rpcError = (code: number) => Object.assign(new Error('rpc'), { code })

const review = {
  digest: 'd'.repeat(64),
  display_name: 'Scout',
  suggested_name: 'scout-2',
  suggested_display_name: 'Scout 2',
  soul: 'You are Scout. Keep builds green.',
  model: { default: 'claude-sonnet-4', provider: 'openrouter' },
  toolsets: ['web', 'file'],
  skills: [
    { files: 2, has_scripts: true, name: 'review' },
    { files: 1, has_scripts: false, name: 'plan' }
  ],
  mcp_servers: [
    {
      command: "tracker-mcp --workspace main --api-key ''",
      enabled: false,
      name: 'tracker',
      needs: ['TRACKER_TOKEN', 'REGION', '--api-key'],
      transport: 'stdio'
    },
    {
      enabled: false,
      name: 'remote',
      needs: ['Authorization'],
      transport: 'sse',
      url: 'https://mcp.example.com/v1/sse'
    }
  ],
  routines: [
    { name: 'Morning digest', prompt: 'Summarize overnight failures', schedule: '0 9 * * *' },
    { name: 'Queue poll', prompt: 'Poll the queue', schedule: 'every 30m' }
  ],
  skipped_routines: ['Broken one']
}

function answer(overrides: Partial<Record<string, unknown>> = {}) {
  request.mockImplementation(async (method, params) => {
    if (method !== 'profiles.template.import') {
      return { ok: true }
    }

    return params?.dry_run
      ? { dry_run: true, review: { ...review, ...overrides } }
      : { dry_run: false, name: params?.name, display_name: params?.display_name, routines_imported: 2 }
  })
}

async function openDialog() {
  render(<BotTemplateImportDialog />)
  act(() => $botTemplateFile.set({ data: 'QUJD', name: 'scout.hermesbot' }))
}

beforeEach(() => {
  request.mockReset()
  notify.mockReset()
  createCanonicalChat.mockClear()
  closeBotTemplateImport()
})

afterEach(() => {
  cleanup()
})

describe('review step', () => {
  it('shows what the bot will be able to do before anything is created', async () => {
    answer()
    await openDialog()

    await screen.findByText('This bot will be able to:')
    expect(screen.getByText('Use these tools: web, file')).toBeTruthy()
    expect(screen.getByText('Use 2 skills')).toBeTruthy()
    expect(screen.getByText('review, plan')).toBeTruthy()
    expect(screen.getByText('Some skills include scripts it can run')).toBeTruthy()
    expect(
      screen.getByText("Run tracker on this computer (local program): tracker-mcp --workspace main --api-key ''")
    ).toBeTruthy()
    expect(screen.getByText('Needs your own credentials: TRACKER_TOKEN, REGION, --api-key')).toBeTruthy()
    expect(screen.getByText('Connect to remote at https://mcp.example.com/v1/sse (SSE)')).toBeTruthy()
    expect(screen.getByText('Needs your own credentials: Authorization')).toBeTruthy()
    expect(screen.getByText('Connections start turned off. Turn each one on yourself once you trust it.')).toBeTruthy()
    expect(screen.getByText('Run 2 routines on a schedule')).toBeTruthy()
    expect(screen.getByText('Routines start paused until you resume them')).toBeTruthy()
    expect(screen.getByText(/Broken one/)).toBeTruthy()
    expect(screen.getByText('You are Scout. Keep builds green.')).toBeTruthy()
    expect(request.mock.calls.filter(([, params]) => !params?.dry_run)).toEqual([])
  })

  it('says so when the template carries no custom instructions or pinned tools', async () => {
    answer({ mcp_servers: [], routines: [], skills: [], skipped_routines: [], soul: '', toolsets: null })
    await openDialog()

    await screen.findByText('Use the default tools')
    expect(screen.getByText('This template has no custom instructions.')).toBeTruthy()
    expect(screen.queryByText(/routine/)).toBeNull()
    expect(screen.queryByText(/Connections start turned off/)).toBeNull()
  })

  it('offers no way to continue when the file is not a template', async () => {
    request.mockRejectedValue(rpcError(4071))
    await openDialog()

    await screen.findByText('This is not a valid Hermes bot template.')
    expect(screen.queryByRole('button', { name: 'Import bot' })).toBeNull()
  })

  it.each([
    [4074, 'This template needs a newer version of Hermes.'],
    [4075, 'This template is too large to import.'],
    [-32601, 'Update Hermes on this machine to import bots.']
  ])('explains review failure %s', async (code, message) => {
    request.mockRejectedValue(rpcError(code))
    await openDialog()

    await screen.findByText(message)
  })
})

describe('commit', () => {
  it('imports the reviewed bytes under the suggested name and opens the new bot', async () => {
    answer()
    await openDialog()
    const input = (await screen.findByLabelText('Name')) as HTMLInputElement
    expect(input.value).toBe('Scout 2')

    fireEvent.click(screen.getByRole('button', { name: 'Import bot' }))

    await waitFor(() => expect($botTemplateFile.get()).toBeNull())
    expect(request).toHaveBeenCalledWith('profiles.template.import', {
      data: 'QUJD',
      display_name: 'Scout 2',
      name: 'scout-2',
      reviewed_digest: review.digest
    })
    expect(notify).toHaveBeenCalledWith(expect.objectContaining({ kind: 'success', message: 'Imported Scout 2' }))
    expect(createCanonicalChat).toHaveBeenCalledWith('scout-2', { kickoff: true })
  })

  it('derives a valid profile name from the name the owner types', async () => {
    answer()
    await openDialog()
    const input = await screen.findByLabelText('Name')

    fireEvent.change(input, { target: { value: 'Build Watcher' } })
    fireEvent.click(screen.getByRole('button', { name: 'Import bot' }))

    await waitFor(() => expect($botTemplateFile.get()).toBeNull())
    expect(request).toHaveBeenCalledWith(
      'profiles.template.import',
      expect.objectContaining({ display_name: 'Build Watcher', name: 'build-watcher' })
    )
  })

  it('will not import under a name that cannot be a profile', async () => {
    answer()
    await openDialog()
    const input = await screen.findByLabelText('Name')

    fireEvent.change(input, { target: { value: '   ' } })

    expect((screen.getByRole('button', { name: 'Import bot' }) as HTMLButtonElement).disabled).toBe(true)
  })

  it('keeps the dialog open with the reason when the name is taken, and lets the owner retry', async () => {
    answer()
    await openDialog()
    await screen.findByLabelText('Name')
    request.mockImplementation(async (_method, params) => {
      if (params?.dry_run) {
        return { dry_run: true, review }
      }

      throw rpcError(4073)
    })

    fireEvent.click(screen.getByRole('button', { name: 'Import bot' }))

    await screen.findByText('That name is already taken. Choose another.')
    expect($botTemplateFile.get()).not.toBeNull()
    expect((screen.getByRole('button', { name: 'Import bot' }) as HTMLButtonElement).disabled).toBe(false)
    expect(createCanonicalChat).not.toHaveBeenCalled()
  })

  it('asks for a fresh review when the bytes changed after it', async () => {
    answer()
    await openDialog()
    await screen.findByLabelText('Name')
    request.mockImplementation(async (_method, params) => {
      if (params?.dry_run) {
        return { dry_run: true, review }
      }

      throw rpcError(4072)
    })

    fireEvent.click(screen.getByRole('button', { name: 'Import bot' }))

    await screen.findByText('The template changed after you reviewed it. Open it again.')
  })

  it('does not birth a canonical chat with the model unset, and says what is needed', async () => {
    request.mockImplementation(async (method, params) => {
      if (method === 'setup.runtime_check') {
        return { ok: false }
      }

      return params?.dry_run
        ? { dry_run: true, review }
        : { dry_run: false, name: params?.name, display_name: params?.display_name }
    })
    await openDialog()
    await screen.findByLabelText('Name')

    fireEvent.click(screen.getByRole('button', { name: 'Import bot' }))

    await waitFor(() => expect(createCanonicalChat).toHaveBeenCalledWith('scout-2', { kickoff: false }))
    expect(notify).toHaveBeenCalledWith(
      expect.objectContaining({ kind: 'warning', message: 'Choose a model for this bot before it can reply.' })
    )
  })

  it('cancels without importing and drops the file', async () => {
    answer()
    await openDialog()
    await screen.findByLabelText('Name')

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))

    expect($botTemplateFile.get()).toBeNull()
    expect(request.mock.calls.filter(([, params]) => !params?.dry_run)).toEqual([])
  })
})

describe('Import bot… menu entry', () => {
  const renderItem = () =>
    render(
      <DropdownMenu open>
        <DropdownMenuContent>
          <BotTemplateImportMenuItem />
        </DropdownMenuContent>
      </DropdownMenu>
    )

  it('appears on a gateway that knows templates', async () => {
    request.mockRejectedValue(rpcError(4076))
    renderItem()

    expect(await screen.findByText('Import bot…')).toBeTruthy()
  })

  it('is absent on a gateway that does not', async () => {
    request.mockRejectedValue(rpcError(-32601))
    renderItem()

    await waitFor(() => expect(request).toHaveBeenCalled())
    expect(screen.queryByText('Import bot…')).toBeNull()
  })
})
