/**
 * Bot templates, the data side: export hands the gateway's bytes to a save dialog, import reviews
 * the exact bytes before committing them, and every failure the gateway can name maps to one the
 * dialog can explain. Hosts without the native file capability fall back to a browser download.
 */

import type * as HermesSdk from '@hermes/plugin-sdk'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { notify, request, requestProfile } = vi.hoisted(() => ({
  notify: vi.fn(),
  request: vi.fn<(method: string, params?: Record<string, unknown>) => Promise<unknown>>(),
  requestProfile: vi.fn<(...args: unknown[]) => Promise<unknown>>()
}))

vi.mock('@hermes/plugin-sdk', async importOriginal => {
  const sdk = await importOriginal<typeof HermesSdk>()

  return { ...sdk, host: { ...sdk.host, notify, request, requestProfile } }
})

const {
  exportBotTemplate,
  importTemplate,
  pickTemplateFile,
  probeTemplateSupport,
  reviewTemplate,
  templateFailure,
  TemplateFileError
} = await import('./bot-template')

const rpcError = (code: number) => Object.assign(new Error('rpc'), { code })

const review = {
  digest: 'a'.repeat(64),
  display_name: 'Scout',
  suggested_name: 'scout-2',
  suggested_display_name: 'Scout 2'
}

const bot = { name: 'scout' }

let saveBotTemplate: ReturnType<typeof vi.fn>
let openBotTemplate: ReturnType<typeof vi.fn>

beforeEach(() => {
  vi.clearAllMocks()
  saveBotTemplate = vi.fn()
  openBotTemplate = vi.fn()
  Object.assign(window, { hermesDesktop: { saveBotTemplate, openBotTemplate } })
})

afterEach(() => {
  delete (window as { hermesDesktop?: unknown }).hermesDesktop
  vi.restoreAllMocks()
})

describe('exportBotTemplate', () => {
  it('asks the bot’s gateway for the template and hands its bytes to the save dialog', async () => {
    request.mockResolvedValue({ data: 'QUJD', filename: 'scout.hermesbot', sha256: 'x', size: 3 })
    saveBotTemplate.mockResolvedValue({ path: '/tmp/scout.hermesbot', saved: true })

    await expect(exportBotTemplate(bot)).resolves.toBe('saved')

    expect(request).toHaveBeenCalledWith('profiles.template.export', { name: 'scout' })
    expect(saveBotTemplate).toHaveBeenCalledWith({ data: 'QUJD', suggestedName: 'scout.hermesbot' })
  })

  it('reports a cancelled dialog as cancelled, not as a failure', async () => {
    request.mockResolvedValue({ data: 'QUJD', filename: 'scout.hermesbot' })
    saveBotTemplate.mockResolvedValue({ canceled: true, saved: false })

    await expect(exportBotTemplate(bot)).resolves.toBe('canceled')
  })

  it('routes a bot that lives on another connection through its own gateway', async () => {
    requestProfile.mockResolvedValue({ data: 'QUJD', filename: 'far.hermesbot' })
    saveBotTemplate.mockResolvedValue({ saved: true })
    const remote = { connectionId: 'ssh-1', name: 'far', remoteSource: true, route: { connectionId: 'ssh-1', mode: 'remote', profile: 'far', targetProfile: 'far' } }

    await exportBotTemplate(remote as never)

    expect(requestProfile).toHaveBeenCalled()
    expect(request).not.toHaveBeenCalled()
  })

  it('names an older gateway instead of failing generically', async () => {
    request.mockRejectedValue(rpcError(-32601))

    await expect(exportBotTemplate(bot)).rejects.toSatisfy(error => templateFailure(error) === 'unsupported')
    expect(saveBotTemplate).not.toHaveBeenCalled()
  })

  it('downloads through the browser when the host has no native save dialog', async () => {
    delete (window as { hermesDesktop?: unknown }).hermesDesktop
    request.mockResolvedValue({ data: btoa('hello'), filename: 'scout.hermesbot' })
    const create = vi.fn(() => 'blob:template')
    const revoke = vi.fn()
    Object.assign(URL, { createObjectURL: create, revokeObjectURL: revoke })
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => undefined)

    await expect(exportBotTemplate(bot)).resolves.toBe('saved')

    expect(click).toHaveBeenCalledTimes(1)
    const blob = (create.mock.calls[0] as unknown as [Blob])[0]
    expect(await blob.text()).toBe('hello')
    expect(revoke).toHaveBeenCalledWith('blob:template')
  })
})

describe('pickTemplateFile', () => {
  it('returns the picked template’s name and bytes', async () => {
    openBotTemplate.mockResolvedValue({ canceled: false, data: 'QUJD', name: 'scout.hermesbot', size: 3 })

    await expect(pickTemplateFile()).resolves.toEqual({ data: 'QUJD', name: 'scout.hermesbot' })
  })

  it('returns null when the dialog is cancelled', async () => {
    openBotTemplate.mockResolvedValue({ canceled: true })

    await expect(pickTemplateFile()).resolves.toBeNull()
  })

  it('maps the native refusals to failures the dialog can explain', async () => {
    openBotTemplate.mockRejectedValue(new Error('Template too large'))
    await expect(pickTemplateFile()).rejects.toSatisfy(error => templateFailure(error) === 'too-large')

    openBotTemplate.mockRejectedValue(new Error('Not a bot template'))
    await expect(pickTemplateFile()).rejects.toSatisfy(error => templateFailure(error) === 'invalid')

    openBotTemplate.mockRejectedValue(new Error('EACCES'))
    await expect(pickTemplateFile()).rejects.toBeInstanceOf(TemplateFileError)
  })
})

describe('reviewTemplate / importTemplate', () => {
  it('reviews with a dry run and returns what the template carries', async () => {
    request.mockResolvedValue({ dry_run: true, review })

    await expect(reviewTemplate('QUJD')).resolves.toEqual(review)

    expect(request).toHaveBeenCalledWith('profiles.template.import', { data: 'QUJD', dry_run: true })
  })

  it('commits the exact bytes that were reviewed, under the chosen name', async () => {
    request.mockResolvedValue({ dry_run: false, name: 'helper', display_name: 'Helper', routines_imported: 1 })

    const result = await importTemplate(
      { data: 'QUJD', name: 'scout.hermesbot' },
      review as never,
      { displayName: 'Helper', name: 'helper' }
    )

    expect(result.name).toBe('helper')
    expect(request).toHaveBeenCalledWith('profiles.template.import', {
      data: 'QUJD',
      display_name: 'Helper',
      name: 'helper',
      reviewed_digest: review.digest
    })
  })
})

describe('templateFailure', () => {
  it.each([
    [4071, 'invalid'],
    [4072, 'changed'],
    [4073, 'name-taken'],
    [4074, 'newer'],
    [4075, 'too-large'],
    [4076, 'invalid'],
    [-32601, 'unsupported'],
    [5071, 'failed']
  ])('maps gateway code %s to %s', (code, expected) => {
    expect(templateFailure(rpcError(code))).toBe(expected)
    expect(templateFailure(new Error('wrapped', { cause: rpcError(code) }))).toBe(expected)
  })

  it('treats anything else as a generic failure', () => {
    expect(templateFailure(new Error('boom'))).toBe('failed')
    expect(templateFailure(null)).toBe('failed')
  })
})

describe('probeTemplateSupport', () => {
  it('is true when the gateway answers the probe at all', async () => {
    request.mockRejectedValue(rpcError(4076))

    await expect(probeTemplateSupport()).resolves.toBe(true)
    expect(request).toHaveBeenCalledWith('profiles.template.import', { data: '', dry_run: true })
  })

  it('is false on a gateway that does not know the method', async () => {
    request.mockRejectedValue(rpcError(-32601))

    await expect(probeTemplateSupport()).resolves.toBe(false)
  })
})
