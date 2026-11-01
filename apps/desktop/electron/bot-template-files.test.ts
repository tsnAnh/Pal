import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

import { afterEach, describe, expect, it } from 'vitest'

import {
  BOT_TEMPLATE_MAX_BYTES,
  type BotTemplateFileDeps,
  openBotTemplateFile,
  registerBotTemplateFilesIpc,
  saveBotTemplateFile
} from './bot-template-files'

const scratch: string[] = []

function tempDir(): string {
  const dir = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'bot-template-'))
  scratch.push(dir)

  return dir
}

afterEach(() => {
  for (const dir of scratch.splice(0)) {
    fs.rmSync(dir, { force: true, recursive: true })
  }
})

const bytes = Buffer.from([0x1f, 0x8b, 0x08, 0x00, 0xde, 0xad, 0xbe, 0xef])

function deps(overrides: Partial<BotTemplateFileDeps> = {}): BotTemplateFileDeps {
  return {
    defaultDir: () => '/home/u/Documents',
    showOpenDialog: async () => ({ canceled: true, filePaths: [] }),
    showSaveDialog: async () => ({ canceled: true }),
    ...overrides
  }
}

describe('saveBotTemplateFile', () => {
  it('writes the exact bytes where the user chose, offering a bare suggested name', async () => {
    const dir = tempDir()
    const target = path.join(dir, 'scout.hermesbot')
    let seen: Parameters<BotTemplateFileDeps['showSaveDialog']>[0] | null = null

    const result = await saveBotTemplateFile(
      { data: bytes.toString('base64'), suggestedName: '../../etc/scout.hermesbot' },
      deps({
        defaultDir: () => dir,
        showSaveDialog: async options => {
          seen = options

          return { canceled: false, filePath: target }
        }
      })
    )

    expect(result).toEqual({ saved: true, path: target })
    expect(fs.readFileSync(target)).toEqual(bytes)
    expect(seen!.defaultPath).toBe(path.join(dir, 'scout.hermesbot'))
    expect(seen!.filters).toEqual([{ extensions: ['hermesbot'], name: 'Hermes bot template' }])
    expect(seen!.properties).toEqual(['createDirectory', 'showOverwriteConfirmation'])
  })

  it('keeps the template extension even when the user types another one', async () => {
    const dir = tempDir()

    const result = await saveBotTemplateFile(
      { data: bytes.toString('base64'), suggestedName: 'scout.hermesbot' },
      deps({ showSaveDialog: async () => ({ canceled: false, filePath: path.join(dir, 'scout.zip') }) })
    )

    expect(result).toEqual({ saved: true, path: path.join(dir, 'scout.zip.hermesbot') })
    expect(fs.existsSync(path.join(dir, 'scout.zip'))).toBe(false)
  })

  it('re-prompts instead of overwriting when the appended extension lands on an existing file', async () => {
    const dir = tempDir()
    const existing = path.join(dir, 'scout.hermesbot')
    const prompts: Array<string | undefined> = []
    const previous = Buffer.from('keep me')

    fs.writeFileSync(existing, previous)

    const result = await saveBotTemplateFile(
      { data: bytes.toString('base64'), suggestedName: 'scout' },
      deps({
        showSaveDialog: async options => {
          prompts.push(options.defaultPath)

          return prompts.length === 1 ? { canceled: false, filePath: path.join(dir, 'scout') } : { canceled: true }
        }
      })
    )

    expect(result).toEqual({ canceled: true, saved: false })
    expect(prompts[1]).toBe(existing)
    expect(fs.readFileSync(existing)).toEqual(previous)
  })

  it('overwrites the appended-extension file once the user confirms it in the re-prompt', async () => {
    const dir = tempDir()
    const existing = path.join(dir, 'scout.hermesbot')
    let calls = 0

    fs.writeFileSync(existing, 'old')

    const result = await saveBotTemplateFile(
      { data: bytes.toString('base64'), suggestedName: 'scout' },
      deps({
        showSaveDialog: async () => {
          calls += 1

          return { canceled: false, filePath: calls === 1 ? path.join(dir, 'scout') : existing }
        }
      })
    )

    expect(result).toEqual({ path: existing, saved: true })
    expect(fs.readFileSync(existing)).toEqual(bytes)
  })

  it('writes nothing when the dialog is cancelled', async () => {
    const result = await saveBotTemplateFile({ data: bytes.toString('base64') }, deps())

    expect(result).toEqual({ canceled: true, saved: false })
  })

  it('refuses malformed or oversized payloads before opening a dialog', async () => {
    let opened = false

    const guarded = deps({
      showSaveDialog: async () => {
        opened = true

        return { canceled: true }
      }
    })

    await expect(saveBotTemplateFile({ data: 42 }, guarded)).rejects.toThrow('Invalid template data')
    await expect(saveBotTemplateFile({ data: '' }, guarded)).rejects.toThrow('Invalid template data')
    await expect(saveBotTemplateFile({ data: 'not base64 !!' }, guarded)).rejects.toThrow('Invalid template data')

    await expect(
      saveBotTemplateFile({ data: Buffer.alloc(BOT_TEMPLATE_MAX_BYTES + 1).toString('base64') }, guarded)
    ).rejects.toThrow('Template too large')
    expect(opened).toBe(false)
  })
})

describe('openBotTemplateFile', () => {
  it('returns the picked template as base64 with its file name', async () => {
    const file = path.join(tempDir(), 'scout.hermesbot')
    fs.writeFileSync(file, bytes)
    let seen: Parameters<BotTemplateFileDeps['showOpenDialog']>[0] | null = null

    const result = await openBotTemplateFile(
      deps({
        showOpenDialog: async options => {
          seen = options

          return { canceled: false, filePaths: [file] }
        }
      })
    )

    expect(result).toEqual({
      canceled: false,
      data: bytes.toString('base64'),
      name: 'scout.hermesbot',
      size: bytes.length
    })
    expect(seen!.properties).toEqual(['openFile'])
    expect(seen!.filters).toEqual([{ extensions: ['hermesbot'], name: 'Hermes bot template' }])
  })

  it('reports a cancelled pick without reading anything', async () => {
    expect(await openBotTemplateFile(deps())).toEqual({ canceled: true })
  })

  it('refuses a file that is not a template or is too large', async () => {
    const dir = tempDir()
    const wrong = path.join(dir, 'notes.txt')
    const big = path.join(dir, 'big.hermesbot')
    const folder = path.join(dir, 'dir.hermesbot')
    fs.writeFileSync(wrong, 'x')
    fs.writeFileSync(big, Buffer.alloc(BOT_TEMPLATE_MAX_BYTES + 1))
    fs.mkdirSync(folder)

    const pick = (filePath: string) =>
      openBotTemplateFile(deps({ showOpenDialog: async () => ({ canceled: false, filePaths: [filePath] }) }))

    await expect(pick(wrong)).rejects.toThrow('Not a bot template')
    await expect(pick(big)).rejects.toThrow('Template too large')
    await expect(pick(folder)).rejects.toThrow('Not a bot template')
  })
})

describe('registerBotTemplateFilesIpc', () => {
  it('registers exactly the save and open channels', async () => {
    const handlers = new Map<string, (event: unknown, ...args: any[]) => unknown>()
    const dir = tempDir()
    const target = path.join(dir, 'out.hermesbot')

    registerBotTemplateFilesIpc(
      { handle: (channel, listener) => void handlers.set(channel, listener) },
      deps({
        showOpenDialog: async () => ({ canceled: false, filePaths: [target] }),
        showSaveDialog: async () => ({ canceled: false, filePath: target })
      })
    )

    expect([...handlers.keys()].sort()).toEqual(['hermes:botTemplate:open', 'hermes:botTemplate:save'])
    expect(await handlers.get('hermes:botTemplate:save')!(null, { data: bytes.toString('base64') })).toEqual({
      path: target,
      saved: true
    })
    expect(await handlers.get('hermes:botTemplate:open')!(null)).toMatchObject({
      canceled: false,
      name: 'out.hermesbot'
    })
  })
})
