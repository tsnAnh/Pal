import { Checkbox, host } from '@hermes/plugin-sdk'
import { useEffect, useRef } from 'react'

import { botSelectionKey } from './data'
import { botsText, useBots } from './i18n'
import { requestForBot, resolveBotConnectionRoute } from './routing'
import type { RosterRow } from './types'

export interface SendPolicyState {
  ask: boolean
  dirty: boolean
  loaded: boolean
}

export const emptySendPolicy = (): SendPolicyState => ({ ask: true, dirty: false, loaded: false })

function backendProfile(bot: RosterRow): string {
  const route = resolveBotConnectionRoute(bot).route

  return route?.targetProfile || route?.profile || bot.name
}

export async function applySendPolicy(bot: RosterRow, state: SendPolicyState): Promise<boolean> {
  if (!state.loaded || !state.dirty) {
    return true
  }

  try {
    await requestForBot(bot, 'config.set', {
      key: 'bot_mode.drafts',
      profile: backendProfile(bot),
      value: state.ask ? 'true' : 'false'
    })

    return true
  } catch (error) {
    host.notifyError(error, botsText().bot.sendPolicySaveFailed)

    return false
  }
}

interface SendPolicyFieldProps {
  bot: RosterRow
  setState: (update: (prev: SendPolicyState) => SendPolicyState) => void
  state: SendPolicyState
}

export function SendPolicyField({ bot, setState, state }: SendPolicyFieldProps) {
  const b = useBots()
  const botRef = useRef(bot)
  const selectionKey = botSelectionKey(bot)

  botRef.current = bot

  useEffect(() => {
    let cancelled = false

    void (async () => {
      try {
        const result = (await requestForBot(botRef.current, 'config.get', {
          key: 'bot_mode.drafts',
          profile: backendProfile(botRef.current)
        })) as { value?: unknown }

        if (!cancelled) {
          setState(prev => (prev.dirty ? prev : { ask: result?.value !== false, dirty: false, loaded: true }))
        }
      } catch {
        setState(prev => prev)
      }
    })()

    return () => {
      cancelled = true
    }
  }, [selectionKey, setState])

  if (!state.loaded) {
    return null
  }

  return (
    <label className="flex cursor-pointer items-start gap-2 text-xs text-(--ui-text-secondary)">
      <Checkbox
        checked={!state.ask}
        className="mt-0.5"
        onCheckedChange={value => setState(prev => ({ ...prev, ask: !value, dirty: true }))}
      />
      <span className="grid gap-0.5">
        <span className="font-medium text-(--ui-text-primary)">{b.bot.sendWithoutAsking}</span>
        <span>{b.bot.sendWithoutAskingHint}</span>
      </span>
    </label>
  )
}
