import fs from 'node:fs'
import path from 'node:path'

export const BOT_TEMPLATE_EXTENSION = 'hermesbot'
export const BOT_TEMPLATE_MAX_BYTES = 50 * 1024 * 1024

const FILTERS = [{ extensions: [BOT_TEMPLATE_EXTENSION], name: 'Hermes bot template' }]
const MAX_BASE64_LENGTH = Math.ceil(BOT_TEMPLATE_MAX_BYTES / 3) * 4

export interface BotTemplateSaveRequest {
  data?: unknown
  suggestedName?: unknown
}

export interface BotTemplateSaveResult {
  canceled?: boolean
  path?: string
  saved: boolean
}

export type BotTemplateOpenResult = { canceled: true } | { canceled: false; data: string; name: string; size: number }

export interface BotTemplateFileDeps {
  defaultDir: () => string
  showOpenDialog: (options: {
    filters: Array<{ extensions: string[]; name: string }>
    properties: Array<'openFile'>
    title: string
  }) => Promise<{ canceled: boolean; filePaths: string[] }>
  showSaveDialog: (options: {
    defaultPath?: string
    filters: Array<{ extensions: string[]; name: string }>
    properties: Array<'createDirectory' | 'showOverwriteConfirmation'>
    title: string
  }) => Promise<{ canceled: boolean; filePath?: string }>
}

interface IpcMainLike {
  handle: (channel: string, listener: (event: unknown, ...args: any[]) => unknown) => void
}

function decodeTemplate(value: unknown): Buffer {
  if (typeof value !== 'string' || !value || value.length % 4 !== 0) {
    throw new Error('Invalid template data')
  }

  if (value.length > MAX_BASE64_LENGTH) {
    throw new Error('Template too large')
  }

  const bytes = Buffer.from(value, 'base64')

  if (bytes.toString('base64') !== value) {
    throw new Error('Invalid template data')
  }

  if (bytes.length > BOT_TEMPLATE_MAX_BYTES) {
    throw new Error('Template too large')
  }

  return bytes
}

function suggestedFileName(value: unknown): string {
  const base = typeof value === 'string' ? path.basename(value.trim().replaceAll('\\', '/')) : ''
  const name = base && base !== '.' && base !== '..' ? base : 'bot'

  return hasTemplateExtension(name) ? name : `${name}.${BOT_TEMPLATE_EXTENSION}`
}

function hasTemplateExtension(filePath: string): boolean {
  return path.extname(filePath).toLowerCase() === `.${BOT_TEMPLATE_EXTENSION}`
}

export async function saveBotTemplateFile(
  request: BotTemplateSaveRequest,
  deps: BotTemplateFileDeps
): Promise<BotTemplateSaveResult> {
  const bytes = decodeTemplate(request?.data)

  let defaultPath = path.join(deps.defaultDir(), suggestedFileName(request.suggestedName))
  let target: string

  for (;;) {
    const picked = await deps.showSaveDialog({
      defaultPath,
      filters: FILTERS,
      properties: ['createDirectory', 'showOverwriteConfirmation'],
      title: 'Export bot template'
    })

    if (picked.canceled || !picked.filePath) {
      return { canceled: true, saved: false }
    }

    if (hasTemplateExtension(picked.filePath)) {
      target = picked.filePath

      break
    }

    const appended = `${picked.filePath}.${BOT_TEMPLATE_EXTENSION}`

    if (!fs.existsSync(appended)) {
      target = appended

      break
    }

    defaultPath = appended
  }

  await fs.promises.writeFile(target, bytes, { mode: 0o644 })

  return { path: target, saved: true }
}

export async function openBotTemplateFile(deps: BotTemplateFileDeps): Promise<BotTemplateOpenResult> {
  const picked = await deps.showOpenDialog({ filters: FILTERS, properties: ['openFile'], title: 'Import bot' })
  const file = picked.filePaths[0]

  if (picked.canceled || !file) {
    return { canceled: true }
  }

  const stat = await fs.promises.stat(file)

  if (!stat.isFile() || !hasTemplateExtension(file)) {
    throw new Error('Not a bot template')
  }

  if (stat.size > BOT_TEMPLATE_MAX_BYTES) {
    throw new Error('Template too large')
  }

  const bytes = await fs.promises.readFile(file)

  return { canceled: false, data: bytes.toString('base64'), name: path.basename(file), size: bytes.length }
}

export function registerBotTemplateFilesIpc(ipcMain: IpcMainLike, deps: BotTemplateFileDeps): void {
  ipcMain.handle('hermes:botTemplate:save', (_event, request) => saveBotTemplateFile(request || {}, deps))
  ipcMain.handle('hermes:botTemplate:open', () => openBotTemplateFile(deps))
}
