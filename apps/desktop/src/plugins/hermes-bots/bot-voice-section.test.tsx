import type * as HermesSdk from '@hermes/plugin-sdk'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { translateBots } from './i18n-test-helper'
import type { RosterRow } from './types'

interface VoiceStub {
  language: string
  languageKey: null | string
  loading: boolean
  preview: ReturnType<typeof vi.fn>
  previewing: boolean
  provider: string
  saving: boolean
  setLanguage: ReturnType<typeof vi.fn>
  setVoice: ReturnType<typeof vi.fn>
  voice: string
  voiceKey: null | string
  voiceLabels: Record<string, string>
  voices: string[]
}

const sdk = vi.hoisted(() => ({
  notifyError: vi.fn(),
  save: vi.fn(),
  scopes: [] as unknown[],
  settings: null as unknown,
  supported: true
}))

vi.mock('@hermes/plugin-sdk', async importOriginal => {
  const original = await importOriginal<typeof HermesSdk>()

  const mocked: Record<string, unknown> = {
    ...original,
    host: { ...original.host, notifyError: sdk.notifyError },
    saveProfileVoice: (...args: unknown[]) => sdk.save(...args),
    usePluginI18n: () => translateBots
  }

  Object.defineProperty(mocked, 'useProfileVoice', {
    enumerable: true,
    get: () =>
      sdk.supported
        ? (scope: unknown) => {
            sdk.scopes.push(scope)

            return sdk.settings
          }
        : undefined
  })

  return mocked
})

const bot = { name: 'ada' } as RosterRow

const settings = (overrides: Partial<VoiceStub> = {}): VoiceStub => ({
  language: '',
  languageKey: null,
  loading: false,
  preview: vi.fn(async () => undefined),
  previewing: false,
  provider: 'openai',
  saving: false,
  setLanguage: vi.fn(async () => true),
  setVoice: vi.fn(async () => true),
  voice: 'alloy',
  voiceKey: 'tts.openai.voice',
  voiceLabels: {},
  voices: ['alloy', 'nova'],
  ...overrides
})

const loadModule = () => import('./bot-voice-section')
const load = async () => (await loadModule()).BotVoiceSection

const onDraft = vi.fn()
const lastDraft = (from?: unknown) => (onDraft.mock.calls.at(-1)?.[0] as (prev: unknown) => unknown)(from ?? empty())
const empty = () => ({ language: null, languageKey: null, voice: null, voiceKey: null })

const view = (BotVoiceSection: Awaited<ReturnType<typeof load>>, draft: unknown = empty()) =>
  render(<BotVoiceSection bot={bot} draft={draft as never} onDraft={onDraft} />)

describe('BotVoiceSection', () => {
  beforeEach(() => {
    vi.resetModules()
    onDraft.mockReset()
    sdk.save.mockReset().mockResolvedValue(undefined)
    sdk.notifyError.mockReset()
    sdk.scopes = []
    sdk.supported = true
    sdk.settings = settings()
  })

  afterEach(cleanup)

  it('previews the saved voice of the bot profile', async () => {
    const BotVoiceSection = await load()
    const stub = sdk.settings as VoiceStub

    view(BotVoiceSection)

    fireEvent.click(screen.getByRole('button', { name: 'Preview' }))

    await waitFor(() => expect(stub.preview).toHaveBeenCalledTimes(1))
    expect(sdk.scopes.at(-1)).toBe('ada')
  })

  it('shows the current voice in the picker', async () => {
    const BotVoiceSection = await load()

    view(BotVoiceSection)

    expect(screen.getByRole('combobox', { name: 'Voice' }).textContent).toContain('alloy')
  })

  it('falls back to a typed voice when the provider lists none, staging it on blur', async () => {
    sdk.settings = settings({ voice: '', voices: [] })

    const BotVoiceSection = await load()
    const stub = sdk.settings as VoiceStub

    view(BotVoiceSection)

    const input = screen.getByRole('textbox', { name: 'Voice' })

    fireEvent.change(input, { target: { value: ' my-voice ' } })
    fireEvent.blur(input)

    expect(lastDraft()).toMatchObject({ voice: 'my-voice', voiceKey: 'tts.openai.voice' })
    expect(stub.setVoice).not.toHaveBeenCalled()
  })

  it('does not save an unchanged typed voice', async () => {
    sdk.settings = settings({ voice: 'same', voices: [] })

    const BotVoiceSection = await load()
    const stub = sdk.settings as VoiceStub

    view(BotVoiceSection)

    const input = screen.getByRole('textbox', { name: 'Voice' })

    fireEvent.change(input, { target: { value: 'same' } })
    fireEvent.blur(input)

    expect(onDraft).not.toHaveBeenCalled()
    expect(stub.setVoice).not.toHaveBeenCalled()
  })

  it('offers a language only when the provider has one and stages it on blur', async () => {
    sdk.settings = settings({ language: 'en', languageKey: 'tts.xai.language' })

    const BotVoiceSection = await load()
    const stub = sdk.settings as VoiceStub

    view(BotVoiceSection)

    const input = screen.getByRole('textbox', { name: 'Voice chat language' })

    fireEvent.change(input, { target: { value: 'ja' } })
    fireEvent.blur(input)

    expect(lastDraft()).toMatchObject({ language: 'ja', languageKey: 'tts.xai.language' })
    expect(stub.setLanguage).not.toHaveBeenCalled()
  })

  it('has no language row for providers without one', async () => {
    const BotVoiceSection = await load()

    view(BotVoiceSection)

    expect(screen.queryByRole('textbox', { name: 'Voice chat language' })).toBeNull()
  })

  it('renders nothing for a provider with no voice setting', async () => {
    sdk.settings = settings({ voiceKey: null, voices: [] })

    const BotVoiceSection = await load()
    const { container } = view(BotVoiceSection)

    expect(container.innerHTML).toBe('')
  })

  it('renders nothing on a desktop build without the voice hook', async () => {
    sdk.supported = false

    const BotVoiceSection = await load()
    const { container } = view(BotVoiceSection)

    expect(container.innerHTML).toBe('')
  })

  it('disables preview with no voice chosen and while one is playing', async () => {
    sdk.settings = settings({ voice: '' })

    const BotVoiceSection = await load()

    view(BotVoiceSection)

    expect((screen.getByRole('button', { name: 'Preview' }) as HTMLButtonElement).disabled).toBe(true)
  })

  it('shows the staged voice and holds preview back until it is saved', async () => {
    const BotVoiceSection = await load()

    view(BotVoiceSection, { ...empty(), voice: 'nova', voiceKey: 'tts.openai.voice' })

    expect(screen.getByRole('combobox', { name: 'Voice' }).textContent).toContain('nova')
    expect((screen.getByRole('button', { name: 'Preview' }) as HTMLButtonElement).disabled).toBe(true)
    expect(screen.getByText(translateBots('voice.pendingHint'))).toBeTruthy()
  })

  it('drops the staged voice again when the typed voice returns to the saved one', async () => {
    sdk.settings = settings({ voice: 'alloy', voices: [] })

    const BotVoiceSection = await load()
    const staged = { ...empty(), voice: 'nova', voiceKey: 'tts.openai.voice' }

    view(BotVoiceSection, staged)

    const input = screen.getByRole('textbox', { name: 'Voice' })

    fireEvent.change(input, { target: { value: 'alloy' } })
    fireEvent.blur(input)

    expect(lastDraft(staged)).toMatchObject({ voice: null, voiceKey: null })
  })
})

describe('applyVoiceDraft', () => {
  const draft = { language: 'ja', languageKey: 'tts.xai.language', voice: 'nova', voiceKey: 'tts.openai.voice' }

  beforeEach(() => {
    vi.resetModules()
    sdk.save.mockReset().mockResolvedValue(undefined)
    sdk.notifyError.mockReset()
    sdk.supported = true
  })

  it('writes nothing when nothing was staged', async () => {
    const { applyVoiceDraft } = await loadModule()

    expect(await applyVoiceDraft(bot, { language: null, languageKey: null, voice: null, voiceKey: null })).toBe(true)
    expect(sdk.save).not.toHaveBeenCalled()
  })

  it('saves the staged keys to the bot profile in one write', async () => {
    const { applyVoiceDraft } = await loadModule()

    expect(await applyVoiceDraft(bot, draft)).toBe(true)
    expect(sdk.save).toHaveBeenCalledTimes(1)
    expect(sdk.save).toHaveBeenCalledWith('ada', { 'tts.openai.voice': 'nova', 'tts.xai.language': 'ja' })
  })

  it('reports a refused save and leaves the dialog able to retry', async () => {
    sdk.save.mockRejectedValue(new Error('offline'))

    const { applyVoiceDraft } = await loadModule()

    expect(await applyVoiceDraft(bot, draft)).toBe(false)
    expect(sdk.notifyError).toHaveBeenCalledWith(expect.any(Error), translateBots('voice.saveFailed'))
  })
})
