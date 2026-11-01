import { QueryClientProvider } from '@tanstack/react-query'
import { act, cleanup, renderHook, waitFor } from '@testing-library/react'
import type { ReactNode } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type * as Hermes from '@/hermes'
import type { ProfileScope } from '@/hermes'

const mocks = vi.hoisted(() => ({
  config: {} as Record<string, unknown>,
  elevenLabs: vi.fn(),
  notifyError: vi.fn(),
  playSpeechText: vi.fn(),
  save: vi.fn()
}))

vi.mock('@/hermes', async importOriginal => ({
  ...(await importOriginal<typeof Hermes>()),
  getElevenLabsVoices: (profile?: unknown) => mocks.elevenLabs(profile),
  getHermesConfigRecord: async () => structuredClone(mocks.config),
  saveHermesConfigRecord: (patch: unknown, scope?: unknown) => mocks.save(patch, scope)
}))

vi.mock('@/lib/voice-playback', () => ({ playSpeechText: mocks.playSpeechText }))
vi.mock('@/store/notifications', () => ({ notify: vi.fn(), notifyError: mocks.notifyError }))

import { queryClient } from '@/lib/query-client'

import { type ProfileVoiceLabels, ttsLanguageKey, ttsVoiceKey, useProfileVoice } from './profile-voice'

const labels: ProfileVoiceLabels = {
  previewFailed: 'preview failed',
  previewText: 'hello there',
  saveFailed: 'save failed'
}

const scope: ProfileScope = { connectionId: 'remote-1', profile: 'ada' }

const wrapper = ({ children }: { children: ReactNode }) => (
  <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
)

const mount = async (profile: ProfileScope = scope) => {
  const view = renderHook(() => useProfileVoice(profile, labels), { wrapper })

  await waitFor(() => expect(view.result.current.loading).toBe(false))

  return view
}

describe('useProfileVoice', () => {
  beforeEach(() => {
    queryClient.clear()
    mocks.save.mockReset().mockResolvedValue({ ok: true })
    mocks.playSpeechText.mockReset().mockResolvedValue(true)
    mocks.notifyError.mockReset()
    mocks.elevenLabs.mockReset().mockResolvedValue({ available: false, voices: [] })
    mocks.config = { tts: { provider: 'openai', openai: { model: 'gpt-4o-mini-tts', voice: 'alloy' } } }
  })

  afterEach(cleanup)

  it('lists the configured provider voices and the saved one', async () => {
    const { result } = await mount()

    expect(result.current.provider).toBe('openai')
    expect(result.current.voiceKey).toBe('tts.openai.voice')
    expect(result.current.voice).toBe('alloy')
    expect(result.current.voices).toEqual(expect.arrayContaining(['alloy', 'nova', 'marin']))
  })

  it('narrows the list to what the selected model accepts', async () => {
    mocks.config = { tts: { provider: 'openai', openai: { model: 'tts-1', voice: 'alloy' } } }

    const { result } = await mount()

    expect(result.current.voices).toContain('nova')
    expect(result.current.voices).not.toContain('marin')
  })

  it('writes only the picked voice key to THAT profile config', async () => {
    const { result } = await mount()

    let saved = false

    await act(async () => {
      saved = await result.current.setVoice('nova')
    })

    expect(saved).toBe(true)
    expect(mocks.save).toHaveBeenCalledTimes(1)
    expect(mocks.save.mock.calls[0][0]).toEqual({ tts: { openai: { voice: 'nova' } } })
    expect(mocks.save.mock.calls[0][1]).toEqual(scope)
    await waitFor(() => expect(result.current.voice).toBe('nova'))
  })

  it('rolls back and reports when the save fails', async () => {
    mocks.save.mockRejectedValueOnce(new Error('boom'))

    const { result } = await mount()

    let saved = true

    await act(async () => {
      saved = await result.current.setVoice('nova')
    })

    expect(saved).toBe(false)
    expect(mocks.notifyError).toHaveBeenCalledWith(expect.any(Error), 'save failed')
    await waitFor(() => expect(result.current.voice).toBe('alloy'))
    expect(result.current.saving).toBe(false)
  })

  it('previews with the profile owner, not the active one', async () => {
    const { result } = await mount()

    await act(async () => {
      await result.current.preview()
    })

    expect(mocks.playSpeechText).toHaveBeenCalledWith('hello there', {
      connectionId: 'remote-1',
      profile: 'ada',
      source: 'read-aloud'
    })
    expect(mocks.notifyError).not.toHaveBeenCalled()
    expect(result.current.previewing).toBe(false)
  })

  it('reports a preview that produced no audio and one that throws', async () => {
    const { result } = await mount()

    mocks.playSpeechText.mockResolvedValueOnce(false)
    await act(async () => result.current.preview())
    expect(mocks.notifyError).toHaveBeenLastCalledWith(expect.any(Error), 'preview failed')

    mocks.playSpeechText.mockRejectedValueOnce(new Error('offline'))
    await act(async () => result.current.preview())
    expect(mocks.notifyError).toHaveBeenCalledTimes(2)
    expect(result.current.previewing).toBe(false)
  })

  it('uses the live account voices for the provider that has them', async () => {
    mocks.config = { tts: { provider: 'elevenlabs', elevenlabs: { voice_id: 'v-1' } } }
    mocks.elevenLabs.mockResolvedValue({
      available: true,
      voices: [
        { label: 'Rachel', voice_id: 'v-1' },
        { label: 'Clyde', voice_id: 'v-2' }
      ]
    })

    const { result } = await mount(scope)

    await waitFor(() => expect(result.current.voices).toEqual(['v-1', 'v-2']))
    expect(result.current.voiceLabels).toEqual({ 'v-1': 'Rachel', 'v-2': 'Clyde' })
    expect(mocks.elevenLabs).toHaveBeenCalledWith(scope)
  })

  it('exposes a language setting only where the provider has one', async () => {
    mocks.config = { tts: { provider: 'xai', xai: { language: 'en', voice_id: 'eve' } } }

    const { result } = await mount()

    expect(result.current.languageKey).toBe('tts.xai.language')
    expect(result.current.language).toBe('en')

    await act(async () => void (await result.current.setLanguage('ja')))
    expect(mocks.save.mock.calls[0][0]).toEqual({ tts: { xai: { language: 'ja' } } })
  })

  it('defaults to the built-in provider and refuses to write a key it does not have', async () => {
    mocks.config = {}

    const { result } = await mount()

    expect(result.current.provider).toBe('edge')

    mocks.config = { tts: { provider: 'custom-command' } }
    queryClient.clear()

    const custom = await mount()

    expect(custom.result.current.voiceKey).toBeNull()

    let saved = true

    await act(async () => {
      saved = await custom.result.current.setVoice('x')
    })

    expect(saved).toBe(false)
    expect(mocks.save).not.toHaveBeenCalled()
  })

  it('maps every voice-bearing provider to a key and only xai to a language', () => {
    for (const provider of [
      'edge',
      'openai',
      'elevenlabs',
      'xai',
      'minimax',
      'mistral',
      'gemini',
      'kittentts',
      'piper',
      'deepinfra'
    ]) {
      expect(ttsVoiceKey(provider)).toMatch(/^tts\./)
    }

    expect(ttsVoiceKey('nope')).toBeNull()
    expect(ttsLanguageKey('xai')).toBe('tts.xai.language')
    expect(ttsLanguageKey('openai')).toBeNull()
  })
})
