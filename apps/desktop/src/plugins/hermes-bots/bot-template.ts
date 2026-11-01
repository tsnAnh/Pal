import { atom, gatewayActivationEpoch, host, queryClient, useGatewayActivationEpoch, useValue } from '@hermes/plugin-sdk'
import { useEffect, useState } from 'react'

import { $selectedBot } from './bot-state'
import { createCanonicalChat } from './canonical-chat'
import { ROSTER_KEY } from './data'
import { requestForBot } from './routing'
import type { RosterRow } from './types'

export interface TemplateModelPin {
  default?: string
  provider?: string
}

export interface TemplateSkill {
  files?: number
  has_scripts?: boolean
  name: string
}

export interface TemplateMcpServer {
  command?: string
  enabled?: boolean
  name: string
  needs?: string[]
  transport?: string
  url?: string
}

export interface TemplateRoutine {
  name: string
  prompt: string
  schedule: string
}

export interface TemplateReview {
  description?: string
  digest: string
  display_name: string
  has_avatar?: boolean
  mcp_servers?: TemplateMcpServer[]
  model?: null | TemplateModelPin
  routines?: TemplateRoutine[]
  size?: number
  skills?: TemplateSkill[]
  skipped_routines?: string[]
  soul?: string
  suggested_display_name: string
  suggested_name: string
  toolsets?: null | string[]
}

export interface TemplateImportResult {
  display_name?: null | string
  name?: null | string
  routines_imported?: number
  routines_skipped?: string[]
}

export interface TemplateFile {
  data: string
  name: string
}

export interface TemplateChoice {
  displayName: string
  name: string
}

export type TemplateFailure = 'changed' | 'failed' | 'invalid' | 'name-taken' | 'newer' | 'too-large' | 'unsupported'
export type TemplateSupport = 'checking' | 'supported' | 'unsupported'

const EXPORT = 'profiles.template.export'
const IMPORT = 'profiles.template.import'
const METHOD_NOT_FOUND = -32601
const MAX_TEMPLATE_BYTES = 50 * 1024 * 1024
const TEMPLATE_EXTENSION = '.hermesbot'
const NAME_RE = /^[a-z0-9][a-z0-9_-]{0,63}$/

const FAILURE_BY_CODE: Record<number, TemplateFailure> = {
  4071: 'invalid',
  4072: 'changed',
  4073: 'name-taken',
  4074: 'newer',
  4075: 'too-large',
  4076: 'invalid',
  [METHOD_NOT_FOUND]: 'unsupported'
}

export class TemplateFileError extends Error {
  readonly failure: TemplateFailure

  constructor(failure: TemplateFailure) {
    super(`bot template file: ${failure}`)
    this.failure = failure
  }
}

export const $botTemplateFile = atom<null | TemplateFile>(null)

export const closeBotTemplateImport = () => $botTemplateFile.set(null)

function rpcCode(error: unknown): number | undefined {
  let node = error

  for (let depth = 0; depth < 4 && node && typeof node === 'object'; depth++) {
    const { cause, code } = node as { cause?: unknown; code?: unknown }

    if (typeof code === 'number') {
      return code
    }

    node = cause
  }

  return undefined
}

export function templateFailure(error: unknown): TemplateFailure {
  if (error instanceof TemplateFileError) {
    return error.failure
  }

  const code = rpcCode(error)

  return (code !== undefined && FAILURE_BY_CODE[code]) || 'failed'
}

export function templateSlug(text: string): null | string {
  const slug = text
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, '-')
    .replace(/^[-_]+|[-_]+$/g, '')
    .slice(0, 64)

  return NAME_RE.test(slug) ? slug : null
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = ''

  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000))
  }

  return btoa(binary)
}

function downloadInBrowser(base64: string, filename: string) {
  const bytes = Uint8Array.from(atob(base64), char => char.charCodeAt(0))
  const url = URL.createObjectURL(new Blob([bytes], { type: 'application/gzip' }))
  const link = document.createElement('a')
  link.href = url
  link.download = filename
  document.body.append(link)
  link.click()
  link.remove()
  URL.revokeObjectURL(url)
}

export async function saveTemplateFile(data: string, filename: string): Promise<'canceled' | 'saved'> {
  const save = window.hermesDesktop?.saveBotTemplate

  if (!save) {
    downloadInBrowser(data, filename)

    return 'saved'
  }

  const result = await save({ data, suggestedName: filename })

  return result.saved ? 'saved' : 'canceled'
}

export async function exportBotTemplate(bot: RosterRow): Promise<'canceled' | 'saved'> {
  const template = await requestForBot<{ data: string; filename: string }>(bot, EXPORT, { name: bot.name })

  return saveTemplateFile(template.data, template.filename)
}

function pickInBrowser(): Promise<null | TemplateFile> {
  return new Promise((resolve, reject) => {
    const input = document.createElement('input')
    input.type = 'file'
    input.accept = TEMPLATE_EXTENSION

    input.addEventListener('cancel', () => resolve(null))

    input.addEventListener('change', () => {
      const file = input.files?.[0]

      if (!file) {
        resolve(null)

        return
      }

      if (file.size > MAX_TEMPLATE_BYTES) {
        reject(new TemplateFileError('too-large'))

        return
      }

      file
        .arrayBuffer()
        .then(buffer => resolve({ data: bytesToBase64(new Uint8Array(buffer)), name: file.name }))
        .catch(() => reject(new TemplateFileError('failed')))
    })

    input.click()
  })
}

function nativePickFailure(error: unknown): TemplateFileError {
  const message = error instanceof Error ? error.message : String(error)

  if (message.includes('Template too large')) {
    return new TemplateFileError('too-large')
  }

  return new TemplateFileError(message.includes('Not a bot template') ? 'invalid' : 'failed')
}

export async function pickTemplateFile(): Promise<null | TemplateFile> {
  const open = window.hermesDesktop?.openBotTemplate

  if (!open) {
    return pickInBrowser()
  }

  const picked = await open().catch((error: unknown) => {
    throw nativePickFailure(error)
  })

  return picked.canceled ? null : { data: picked.data, name: picked.name }
}

export async function reviewTemplate(data: string): Promise<TemplateReview> {
  const result = await host.request<{ review: TemplateReview }>(IMPORT, { data, dry_run: true })

  return result.review
}

export async function importTemplate(
  file: TemplateFile,
  review: TemplateReview,
  choice: TemplateChoice
): Promise<TemplateImportResult> {
  return host.request<TemplateImportResult>(IMPORT, {
    data: file.data,
    display_name: choice.displayName,
    name: choice.name,
    reviewed_digest: review.digest
  })
}

export async function probeTemplateSupport(): Promise<boolean> {
  try {
    await host.request(IMPORT, { data: '', dry_run: true })
  } catch (error) {
    return rpcCode(error) !== METHOD_NOT_FOUND
  }

  return true
}

export function useBotTemplateSupport(active: boolean): TemplateSupport {
  const connectionId = useValue(host.state.connectionId)
  const profile = useValue(host.state.profile)
  const gateway = useValue(host.state.gateway)
  const epoch = useGatewayActivationEpoch()
  const source = JSON.stringify([connectionId, profile, gateway, epoch])
  const [answer, setAnswer] = useState<null | { source: string; support: TemplateSupport }>(null)

  useEffect(() => {
    if (!active || gateway !== 'open') {
      return
    }

    let cancelled = false

    probeTemplateSupport().then(supported => {
      if (!cancelled && gatewayActivationEpoch() === epoch) {
        setAnswer({ source, support: supported ? 'supported' : 'unsupported' })
      }
    })

    return () => {
      cancelled = true
    }
  }, [active, epoch, gateway, source])

  return answer?.source === source ? answer.support : 'checking'
}

export async function startBotTemplateImport(): Promise<TemplateFailure | null> {
  try {
    const file = await pickTemplateFile()

    if (file) {
      $botTemplateFile.set(file)
    }

    return null
  } catch (error) {
    return templateFailure(error)
  }
}

export async function openImportedBot(slug: string): Promise<{ needsModel: boolean }> {
  if (typeof host.dropLeftoverProfilePrefs === 'function') {
    host.dropLeftoverProfilePrefs(slug, null)
  }

  queryClient.invalidateQueries({ queryKey: ROSTER_KEY })

  const readiness = await host.request<{ ok?: boolean }>('setup.runtime_check', { profile: slug }).catch(() => null)
  const needsModel = readiness?.ok === false
  $selectedBot.set(slug)

  try {
    const sid = await createCanonicalChat(slug, { kickoff: !needsModel })

    if (!sid && typeof host.newChat === 'function') {
      host.newChat(slug)
    }
  } catch {
    if (typeof host.newChat === 'function') {
      host.newChat(slug)
    }
  }

  return { needsModel }
}
