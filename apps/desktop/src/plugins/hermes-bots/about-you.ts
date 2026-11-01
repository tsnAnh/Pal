import { atom, gatewayActivationEpoch, host, useGatewayActivationEpoch, useValue } from '@hermes/plugin-sdk'
import { useEffect, useState } from 'react'

export interface AboutYouFacts {
  name: string
  timezone: string
}

export type AboutYouFailure = 'failed' | 'invalid-timezone'
export type AboutYouSupport = 'checking' | 'supported' | 'unsupported'

const GET = 'bot_mode.about_you.get'
const SET = 'bot_mode.about_you.set'
const METHOD_NOT_FOUND = -32601
const INVALID_TIMEZONE = 4065

export const AUTO_TIMEZONE = 'auto'
export const ABOUT_YOU_NAME_MAX = 80

export const $aboutYouOpen = atom(false)

export const openAboutYou = () => $aboutYouOpen.set(true)

export const closeAboutYou = () => $aboutYouOpen.set(false)

const errorCode = (error: unknown) => (error as { code?: unknown } | null)?.code

export const isAboutYouUnsupported = (error: unknown) => errorCode(error) === METHOD_NOT_FOUND

export const aboutYouFailure = (error: unknown): AboutYouFailure =>
  errorCode(error) === INVALID_TIMEZONE ? 'invalid-timezone' : 'failed'

function normalizeFacts(raw: unknown): AboutYouFacts {
  const facts = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>

  return {
    name: typeof facts.name === 'string' ? facts.name : '',
    timezone: typeof facts.timezone === 'string' ? facts.timezone : ''
  }
}

export function browserTimeZone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || ''
  } catch {
    return ''
  }
}

export function timeZoneChoices(current: string): string[] {
  const supported = typeof Intl.supportedValuesOf === 'function' ? Intl.supportedValuesOf('timeZone') : []

  return [...new Set([...supported, 'UTC', current, browserTimeZone()].filter(Boolean))].sort((a, b) =>
    a.localeCompare(b)
  )
}

export async function loadAboutYou(): Promise<AboutYouFacts> {
  return normalizeFacts(await host.request(GET, {}))
}

export async function saveAboutYou(facts: AboutYouFacts): Promise<AboutYouFacts> {
  return normalizeFacts(await host.request(SET, { name: facts.name, timezone: facts.timezone }))
}

export function useAboutYouSupport(active: boolean): AboutYouSupport {
  const connectionId = useValue(host.state.connectionId)
  const profile = useValue(host.state.profile)
  const gateway = useValue(host.state.gateway)
  const epoch = useGatewayActivationEpoch()
  const source = JSON.stringify([connectionId, profile, gateway, epoch])
  const [answer, setAnswer] = useState<{ source: string; support: AboutYouSupport } | null>(null)

  useEffect(() => {
    if (!active || gateway !== 'open') {
      return
    }

    let cancelled = false

    const settle = (support: AboutYouSupport) => {
      if (!cancelled && gatewayActivationEpoch() === epoch) {
        setAnswer({ source, support })
      }
    }

    loadAboutYou().then(
      () => settle('supported'),
      error => settle(isAboutYouUnsupported(error) ? 'unsupported' : 'supported')
    )

    return () => {
      cancelled = true
    }
  }, [active, epoch, gateway, source])

  return answer?.source === source ? answer.support : 'checking'
}

export function useAboutYouName(): string {
  const connectionId = useValue(host.state.connectionId)
  const profile = useValue(host.state.profile)
  const gateway = useValue(host.state.gateway)
  const editing = useValue($aboutYouOpen)
  const epoch = useGatewayActivationEpoch()
  const [name, setName] = useState('')

  useEffect(() => {
    if (gateway !== 'open' || editing) {
      return
    }

    let cancelled = false

    loadAboutYou().then(
      facts => !cancelled && setName(facts.name.trim()),
      () => !cancelled && setName('')
    )

    return () => {
      cancelled = true
    }
  }, [connectionId, editing, epoch, gateway, profile])

  return name
}
