import { useCallback, useEffect, useMemo, useRef, useState } from 'react'

import { getElevenLabsVoices, type ProfileScope, profileScopeKey, saveHermesConfigRecord } from '@/hermes'
import { playSpeechText } from '@/lib/voice-playback'
import { notifyError } from '@/store/notifications'
import type { HermesConfigRecord } from '@/types/hermes'

import { hermesConfigCacheWriter, invalidateHermesConfig, useHermesConfigRecord } from '../hooks/use-config-record'

import { enumOptionsFor, getNested, setNested } from './helpers'

export const DEFAULT_TTS_PROVIDER = 'edge'

const VOICE_KEYS: Readonly<Record<string, string>> = {
  deepinfra: 'tts.deepinfra.voice',
  edge: 'tts.edge.voice',
  elevenlabs: 'tts.elevenlabs.voice_id',
  gemini: 'tts.gemini.voice',
  kittentts: 'tts.kittentts.voice',
  minimax: 'tts.minimax.voice_id',
  mistral: 'tts.mistral.voice_id',
  openai: 'tts.openai.voice',
  piper: 'tts.piper.voice',
  xai: 'tts.xai.voice_id'
}

const LANGUAGE_KEYS: Readonly<Record<string, string>> = { xai: 'tts.xai.language' }

export function ttsVoiceKey(provider: string): null | string {
  return VOICE_KEYS[provider] ?? null
}

export function ttsLanguageKey(provider: string): null | string {
  return LANGUAGE_KEYS[provider] ?? null
}

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : ''
}

export function ttsProviderOf(config: HermesConfigRecord): string {
  return text(getNested(config, 'tts.provider')) || DEFAULT_TTS_PROVIDER
}

function ownerOf(profile: ProfileScope) {
  return typeof profile === 'object' && profile ? profile : { profile: profile ?? undefined }
}

export interface ProfileVoiceLabels {
  previewFailed: string
  previewText: string
  saveFailed: string
}

export interface ProfileVoice {
  language: string
  languageKey: null | string
  loading: boolean
  preview: () => Promise<void>
  previewing: boolean
  provider: string
  saving: boolean
  setLanguage: (language: string) => Promise<boolean>
  setVoice: (voice: string) => Promise<boolean>
  voice: string
  voiceKey: null | string
  voiceLabels: Record<string, string>
  voices: string[]
}

export async function saveProfileVoice(profile: ProfileScope, entries: Record<string, string>): Promise<void> {
  const patch = Object.entries(entries).reduce<HermesConfigRecord>(
    (record, [key, value]) => setNested(record, key, value),
    {}
  )

  await saveHermesConfigRecord(patch, profile)
  await invalidateHermesConfig(profile)
}

export function useProfileVoice(profile: ProfileScope, labels: ProfileVoiceLabels): ProfileVoice {
  const { data: config, isLoading, writeScope } = useHermesConfigRecord(profile)
  const [saving, setSaving] = useState(false)
  const [previewing, setPreviewing] = useState(false)
  const [elVoices, setElVoices] = useState<null | string[]>(null)
  const [elLabels, setElLabels] = useState<Record<string, string>>({})
  const writeCache = useMemo(() => hermesConfigCacheWriter(profile), [profile])
  const labelsRef = useRef(labels)
  const saveSeq = useRef(0)
  const previewSeq = useRef(0)

  labelsRef.current = labels

  const record = config ?? {}
  const provider = ttsProviderOf(record)
  const voiceKey = ttsVoiceKey(provider)
  const languageKey = ttsLanguageKey(provider)
  const voice = voiceKey ? text(getNested(record, voiceKey)) : ''
  const language = languageKey ? text(getNested(record, languageKey)) : ''
  const profileRef = useRef(profile)
  const scopeKey = profileScopeKey(profile)

  profileRef.current = profile

  useEffect(() => {
    setElVoices(null)
    setElLabels({})

    if (provider !== 'elevenlabs') {
      return
    }

    let cancelled = false

    getElevenLabsVoices(profileRef.current)
      .then(result => {
        if (cancelled || !result.available) {
          return
        }

        setElVoices(result.voices.map(entry => entry.voice_id))
        setElLabels(Object.fromEntries(result.voices.map(entry => [entry.voice_id, entry.label])))
      })
      .catch(() => undefined)

    return () => void (cancelled = true)
  }, [scopeKey, provider])

  const voices = useMemo(() => {
    const listed = voiceKey ? (enumOptionsFor(voiceKey, voice, record, elVoices ?? undefined) ?? []) : []

    return voice && !listed.includes(voice) ? [voice, ...listed] : listed
    // eslint-disable-next-line react-hooks/exhaustive-deps -- `record` identity changes on every refetch; the inputs below are what the list reads
  }, [elVoices, voice, voiceKey, provider, text(getNested(record, 'tts.openai.model'))])

  const write = useCallback(
    async (key: null | string, value: string): Promise<boolean> => {
      if (!key) {
        return false
      }

      const seq = ++saveSeq.current
      const previous = text(getNested(config ?? {}, key))

      writeCache(current => (current ? setNested(current, key, value) : current))
      setSaving(true)

      try {
        await saveHermesConfigRecord(setNested({}, key, value), writeScope ?? profile)

        return true
      } catch (error) {
        writeCache(current => (current ? setNested(current, key, previous) : current))
        notifyError(error, labelsRef.current.saveFailed)

        return false
      } finally {
        if (seq === saveSeq.current) {
          setSaving(false)
        }
      }
    },
    [config, profile, writeCache, writeScope]
  )

  const preview = useCallback(async () => {
    const seq = ++previewSeq.current

    setPreviewing(true)

    try {
      const spoke = await playSpeechText(labelsRef.current.previewText, { ...ownerOf(profile), source: 'read-aloud' })

      if (!spoke) {
        notifyError(new Error('preview unavailable'), labelsRef.current.previewFailed)
      }
    } catch (error) {
      notifyError(error, labelsRef.current.previewFailed)
    } finally {
      if (seq === previewSeq.current) {
        setPreviewing(false)
      }
    }
  }, [profile])

  return {
    language,
    languageKey,
    loading: isLoading,
    preview,
    previewing,
    provider,
    saving,
    setLanguage: value => write(languageKey, value),
    setVoice: value => write(voiceKey, value),
    voice,
    voiceKey,
    voiceLabels: elLabels,
    voices
  }
}
