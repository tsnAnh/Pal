import * as sdk from '@hermes/plugin-sdk'
import { Button, host, Input, Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@hermes/plugin-sdk'
import { useState } from 'react'

import { labeled } from './dialog-parts'
import { botsText, useBots } from './i18n'
import { botBackendProfileScope, resolveBotConnectionRoute } from './routing'
import type { RosterRow } from './types'

const useProfileVoice: typeof sdk.useProfileVoice | undefined =
  'useProfileVoice' in sdk ? sdk.useProfileVoice : undefined

const saveProfileVoice: typeof sdk.saveProfileVoice | undefined =
  'saveProfileVoice' in sdk ? sdk.saveProfileVoice : undefined

export const botVoiceSupported = typeof useProfileVoice === 'function' && typeof saveProfileVoice === 'function'

export interface VoiceDraft {
  language: null | string
  languageKey: null | string
  voice: null | string
  voiceKey: null | string
}

export const emptyVoiceDraft = (): VoiceDraft => ({ language: null, languageKey: null, voice: null, voiceKey: null })

export async function applyVoiceDraft(bot: RosterRow, draft: VoiceDraft): Promise<boolean> {
  const entries: Record<string, string> = {}

  if (draft.voice !== null && draft.voiceKey) {
    entries[draft.voiceKey] = draft.voice
  }

  if (draft.language !== null && draft.languageKey) {
    entries[draft.languageKey] = draft.language
  }

  if (!Object.keys(entries).length || !saveProfileVoice) {
    return true
  }

  try {
    await saveProfileVoice(botBackendProfileScope(resolveBotConnectionRoute(bot).route, bot.name), entries)

    return true
  } catch (error) {
    host.notifyError(error, botsText().voice.saveFailed)

    return false
  }
}

interface BotVoiceSectionProps {
  bot: RosterRow
  draft: VoiceDraft
  onDraft: (update: (prev: VoiceDraft) => VoiceDraft) => void
}

function BotVoiceControls({ bot, draft, onDraft }: BotVoiceSectionProps) {
  const b = useBots()
  const v = b.voice
  const route = resolveBotConnectionRoute(bot).route
  const scope = botBackendProfileScope(route, bot.name)

  const settings = useProfileVoice!(scope, {
    previewFailed: v.previewFailed,
    previewText: v.previewText,
    saveFailed: v.saveFailed
  })

  const [typedVoice, setTypedVoice] = useState<null | string>(null)
  const [typedLanguage, setTypedLanguage] = useState<null | string>(null)

  if (!settings.voiceKey) {
    return null
  }

  const voice = draft.voice ?? settings.voice
  const language = draft.language ?? settings.language
  const pending = draft.voice !== null || draft.language !== null

  const stageVoice = (value: string) =>
    onDraft(prev => ({
      ...prev,
      voice: value === settings.voice ? null : value,
      voiceKey: value === settings.voice ? null : settings.voiceKey
    }))

  const stageLanguage = (value: string) =>
    onDraft(prev => ({
      ...prev,
      language: value === settings.language ? null : value,
      languageKey: value === settings.language ? null : settings.languageKey
    }))

  const commit = (value: null | string, current: string, stage: (next: string) => void, reset: () => void) => {
    const next = value?.trim()

    if (next !== undefined && next !== current) {
      stage(next)
    }

    reset()
  }

  const voices =
    settings.voices.length > 0 && voice && !settings.voices.includes(voice)
      ? [voice, ...settings.voices]
      : settings.voices

  return (
    <div className="grid gap-2" data-slot="bot-voice">
      {labeled(
        v.voice,
        <div className="flex items-center gap-2">
          {voices.length > 0 ? (
            <Select disabled={settings.loading} onValueChange={stageVoice} value={voice}>
              <SelectTrigger aria-label={v.voice} className="h-8 min-w-0 flex-1 text-xs">
                <SelectValue placeholder={v.customVoicePlaceholder} />
              </SelectTrigger>
              <SelectContent>
                {voices.map(option => (
                  <SelectItem key={option} value={option}>
                    {settings.voiceLabels[option] ?? option}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          ) : (
            <Input
              aria-label={v.voice}
              className="h-8 min-w-0 flex-1 text-xs"
              disabled={settings.loading}
              onBlur={() => commit(typedVoice, voice, stageVoice, () => setTypedVoice(null))}
              onChange={event => setTypedVoice(event.target.value)}
              placeholder={v.customVoicePlaceholder}
              value={typedVoice ?? voice}
            />
          )}
          <Button
            disabled={settings.loading || settings.saving || settings.previewing || pending || !settings.voice}
            onClick={() => void settings.preview()}
            size="xs"
            type="button"
            variant="secondary"
          >
            {settings.previewing ? v.previewing : v.preview}
          </Button>
        </div>
      )}
      <p className="text-[0.7rem] text-(--ui-text-tertiary)">{pending ? v.pendingHint : v.hint}</p>
      {settings.languageKey
        ? labeled(
            v.language,
            <>
              <Input
                aria-label={v.language}
                className="h-8 text-xs"
                disabled={settings.loading}
                onBlur={() => commit(typedLanguage, language, stageLanguage, () => setTypedLanguage(null))}
                onChange={event => setTypedLanguage(event.target.value)}
                placeholder={v.languagePlaceholder}
                value={typedLanguage ?? language}
              />
              <p className="text-[0.7rem] text-(--ui-text-tertiary)">{v.languageHint}</p>
            </>
          )
        : null}
    </div>
  )
}

export function BotVoiceSection(props: BotVoiceSectionProps) {
  return botVoiceSupported ? <BotVoiceControls {...props} /> : null
}
