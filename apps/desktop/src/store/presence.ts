import type { ClientAttentionParams, ClientHelloParams, ClientHelloResult, RuntimeDescribeResult } from '@hermes/shared'
import { atom } from 'nanostores'

import type { HermesGateway } from '@/hermes'

import { receiveReachOffer } from './presence-offers'

export type PresenceAttention = ClientAttentionParams['state']

export interface PresenceSignals {
  focused: boolean
  idle: boolean
  visible: boolean
}

export type PresenceGateway = Pick<HermesGateway, 'on' | 'onState' | 'request'>

interface PresenceLink {
  gateway: PresenceGateway
  generation: number
  ready: boolean
  reporting: boolean
  reported: null | PresenceAttention
}

interface PresenceIdentity {
  appVersion: string
  deviceId: string
  label: string
}

const REACH_CAPABILITY = 'reach-v1'
export const ATTENTION_DEBOUNCE_MS = 2000
export const IDLE_POLL_MS = 15_000

const ATTENTION_RULES: readonly (readonly [(signals: PresenceSignals) => boolean, PresenceAttention])[] = [
  [signals => signals.idle, 'idle'],
  [signals => signals.focused && signals.visible, 'foreground']
]

export function attentionFor(signals: PresenceSignals): PresenceAttention {
  return ATTENTION_RULES.find(([matches]) => matches(signals))?.[1] ?? 'background'
}

function readSignals(idle: boolean): PresenceSignals {
  return {
    focused: typeof document.hasFocus === 'function' ? document.hasFocus() : true,
    idle,
    visible: document.visibilityState !== 'hidden'
  }
}

export const $presenceSignals = atom<PresenceSignals>(readSignals(false))
export const $presenceAttention = atom<PresenceAttention>(attentionFor($presenceSignals.get()))

const links = new Set<PresenceLink>()
let identityPromise: null | Promise<null | PresenceIdentity> = null
let debounceTimer: null | ReturnType<typeof setTimeout> = null
let idleTimer: null | ReturnType<typeof setInterval> = null
let detachSignals: null | (() => void) = null

function loadIdentity(): Promise<null | PresenceIdentity> {
  const bridge = window.hermesDesktop

  if (!bridge?.getPresenceIdentity) {
    return Promise.resolve(null)
  }

  identityPromise ??= bridge.getPresenceIdentity().catch(() => {
    identityPromise = null

    return null
  })

  return identityPromise
}

function patchSignals(patch: Partial<PresenceSignals>): void {
  const current = $presenceSignals.get()
  const next = { ...current, ...patch }

  if (next.focused === current.focused && next.idle === current.idle && next.visible === current.visible) {
    return
  }

  $presenceSignals.set(next)

  if (debounceTimer) {
    clearTimeout(debounceTimer)
  }

  debounceTimer = setTimeout(commitAttention, ATTENTION_DEBOUNCE_MS)
}

function commitAttention(): void {
  debounceTimer = null
  const next = attentionFor($presenceSignals.get())

  if (next === $presenceAttention.get()) {
    return
  }

  $presenceAttention.set(next)

  for (const link of links) {
    void reportAttention(link)
  }
}

async function reportAttention(link: PresenceLink): Promise<void> {
  if (link.reporting) {
    return
  }

  const generation = link.generation
  link.reporting = true

  try {
    while (link.ready && link.generation === generation && link.reported !== $presenceAttention.get()) {
      const state = $presenceAttention.get()
      const params: ClientAttentionParams = { state }
      const result = await link.gateway.request<{ recorded?: boolean }>('client.attention', { ...params })

      if (link.generation !== generation || result?.recorded === false) {
        return
      }

      link.reported = state
    }
  } catch {
    return
  } finally {
    if (link.generation === generation) {
      link.reporting = false
    }
  }
}

async function declareDevice(link: PresenceLink): Promise<void> {
  const generation = link.generation
  const identity = await loadIdentity()

  if (!identity || link.generation !== generation) {
    return
  }

  const described = await link.gateway.request<RuntimeDescribeResult>('runtime.describe', {})

  if (link.generation !== generation || !described?.capabilities?.includes(REACH_CAPABILITY)) {
    return
  }

  const attention = $presenceAttention.get()

  const hello: ClientHelloParams = {
    accepts_offers: true,
    app_version: identity.appVersion,
    attention,
    device_id: identity.deviceId,
    kind: 'desktop',
    label: identity.label
  }

  const result = await link.gateway.request<ClientHelloResult>('client.hello', { ...hello })

  if (link.generation !== generation || result?.recorded === false) {
    return
  }

  link.ready = true
  link.reported = attention
  await reportAttention(link)
}

function closeLink(link: PresenceLink): void {
  link.generation += 1
  link.ready = false
  link.reporting = false
  link.reported = null
}

function openLink(link: PresenceLink): void {
  closeLink(link)
  void declareDevice(link).catch(() => undefined)
}

const LINK_STATE_HANDLERS: Partial<Record<string, (link: PresenceLink) => void>> = {
  closed: closeLink,
  error: closeLink,
  open: openLink
}

function pollIdle(): void {
  void window.hermesDesktop
    ?.getSystemIdle?.()
    .then(idle => patchSignals({ idle }))
    .catch(() => undefined)
}

function startSignals(): void {
  const seed = readSignals(false)
  $presenceSignals.set(seed)
  $presenceAttention.set(attentionFor(seed))

  const refresh = () => patchSignals(readSignals($presenceSignals.get().idle))
  window.addEventListener('focus', refresh)
  window.addEventListener('blur', refresh)
  document.addEventListener('visibilitychange', refresh)
  pollIdle()
  idleTimer = setInterval(pollIdle, IDLE_POLL_MS)

  detachSignals = () => {
    window.removeEventListener('focus', refresh)
    window.removeEventListener('blur', refresh)
    document.removeEventListener('visibilitychange', refresh)

    if (idleTimer) {
      clearInterval(idleTimer)
      idleTimer = null
    }

    if (debounceTimer) {
      clearTimeout(debounceTimer)
      debounceTimer = null
    }
  }
}

export function bindGatewayPresence(gateway: PresenceGateway): () => void {
  const link: PresenceLink = { gateway, generation: 0, ready: false, reported: null, reporting: false }

  if (!links.size) {
    startSignals()
  }

  links.add(link)

  const offState = gateway.onState(state => LINK_STATE_HANDLERS[state]?.(link))
  const offOffer = gateway.on('reach.offer', event => receiveReachOffer(gateway, event.payload))

  return () => {
    offState()
    offOffer()
    closeLink(link)
    links.delete(link)

    if (!links.size) {
      detachSignals?.()
      detachSignals = null
    }
  }
}

export function __resetPresenceForTests(): void {
  detachSignals?.()
  detachSignals = null
  links.clear()
  identityPromise = null
  $presenceSignals.set(readSignals(false))
  $presenceAttention.set(attentionFor($presenceSignals.get()))
}
