import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { $nativeNotifyPrefs, setNativeNotifyEnabled, setNativeNotifyKind } from './native-notifications'
import { $notifications, dismissNotification } from './notifications'
import { __resetNativeNotifyBaselineForTests } from './notify-baseline'
import {
  __resetPresenceForTests,
  ATTENTION_DEBOUNCE_MS,
  attentionFor,
  bindGatewayPresence,
  IDLE_POLL_MS,
  type PresenceGateway
} from './presence'
import { __resetPresenceOffersForTests, settleReachOfferNotification, TOAST_LIFETIME_MS } from './presence-offers'

type Handler = (payload: unknown) => unknown

const desktopWindow = window as unknown as { hermesDesktop?: Partial<NonNullable<Window['hermesDesktop']>> }
const initialBridge = desktopWindow.hermesDesktop

const IDENTITY = { appVersion: '1.2.3', deviceId: 'device-aaaa-bbbb', label: 'Desktop (macOS)' }

function setWindowState({ focused, hidden = false }: { focused: boolean; hidden?: boolean }) {
  Object.defineProperty(document, 'hidden', { configurable: true, value: hidden })
  Object.defineProperty(document, 'visibilityState', { configurable: true, value: hidden ? 'hidden' : 'visible' })
  Object.defineProperty(document, 'hasFocus', { configurable: true, value: () => focused })
}

function createGateway(capabilities: string[] = ['reach-v1']) {
  const stateHandlers = new Set<(state: string) => void>()
  const eventHandlers = new Map<string, Handler>()
  let state = 'idle'

  const request = vi.fn(async (method: string, _params?: Record<string, unknown>) => {
    if (method === 'runtime.describe') {
      return { capabilities }
    }

    if (method === 'client.hello') {
      return { recorded: true, same_host: true }
    }

    return { recorded: true }
  })

  const gateway = {
    on: (type: string, handler: Handler) => {
      eventHandlers.set(type, handler)

      return () => eventHandlers.delete(type)
    },
    onState: (handler: (next: string) => void) => {
      stateHandlers.add(handler)
      handler(state)

      return () => stateHandlers.delete(handler)
    },
    request
  }

  return {
    emit: (type: string, payload: unknown) => eventHandlers.get(type)?.({ payload, type }),
    gateway: gateway as unknown as PresenceGateway,
    setState: (next: string) => {
      state = next

      for (const handler of stateHandlers) {
        handler(next)
      }
    },
    sent: (method: string) =>
      request.mock.calls.filter(([name]) => name === method).map(([, params]) => params as Record<string, unknown>)
  }
}

const settle = async () => {
  await vi.advanceTimersByTimeAsync(0)
  await vi.advanceTimersByTimeAsync(0)
}

let idle = false
let testClock = 0
const notify = vi.fn().mockResolvedValue(true)
let unbind: Array<() => void> = []

function connect(capabilities?: string[]) {
  const fake = createGateway(capabilities)
  unbind.push(bindGatewayPresence(fake.gateway))

  return fake
}

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(Date.now() + 60_000 * (testClock += 1))
  idle = false
  notify.mockClear()
  setWindowState({ focused: true })
  desktopWindow.hermesDesktop = {
    getPresenceIdentity: vi.fn().mockResolvedValue(IDENTITY),
    getSystemIdle: vi.fn(async () => idle),
    notify
  }
  setNativeNotifyEnabled(true)
  setNativeNotifyKind('proactive', true)
  __resetNativeNotifyBaselineForTests()
  __resetPresenceForTests()
  __resetPresenceOffersForTests()
  $notifications.set([])
  unbind = []
})

afterEach(() => {
  for (const off of unbind) {
    off()
  }

  vi.useRealTimers()
  desktopWindow.hermesDesktop = initialBridge
})

describe('attentionFor', () => {
  it.each([
    [{ focused: true, idle: false, visible: true }, 'foreground'],
    [{ focused: false, idle: false, visible: true }, 'background'],
    [{ focused: true, idle: false, visible: false }, 'background'],
    [{ focused: true, idle: true, visible: true }, 'idle']
  ] as const)('%j -> %s', (signals, expected) => {
    expect(attentionFor(signals)).toBe(expected)
  })
})

describe('client.hello', () => {
  it('declares the desktop device once the gateway opens and advertises reach-v1', async () => {
    const fake = connect()
    fake.setState('open')
    await settle()

    expect(fake.sent('client.hello')).toEqual([
      {
        accepts_offers: true,
        app_version: '1.2.3',
        attention: 'foreground',
        device_id: 'device-aaaa-bbbb',
        kind: 'desktop',
        label: 'Desktop (macOS)'
      }
    ])
  })

  it('declares again on every reconnect', async () => {
    const fake = connect()
    fake.setState('open')
    await settle()
    fake.setState('closed')
    fake.setState('open')
    await settle()

    expect(fake.sent('client.hello')).toHaveLength(2)
  })

  it('stays silent against a backend without reach-v1', async () => {
    const fake = connect(['event-replay-v1'])
    fake.setState('open')
    await settle()

    expect(fake.sent('runtime.describe')).toHaveLength(1)
    expect(fake.sent('client.hello')).toHaveLength(0)
  })

  it('tolerates an older backend refusing runtime.describe', async () => {
    const fake = connect()
    fake.gateway.request = vi.fn().mockRejectedValue(new Error('method not found'))
    fake.setState('open')
    await settle()

    expect(fake.gateway.request).toHaveBeenCalledTimes(1)
  })

  it('sends nothing without the desktop bridge', async () => {
    desktopWindow.hermesDesktop = { notify }
    const fake = connect()
    fake.setState('open')
    await settle()

    expect(fake.sent('runtime.describe')).toHaveLength(0)
  })

  it('does not declare when the socket closes before the capability answer lands', async () => {
    const fake = connect()
    fake.setState('open')
    fake.setState('closed')
    await settle()

    expect(fake.sent('client.hello')).toHaveLength(0)
  })
})

describe('client.attention', () => {
  async function connected() {
    const fake = connect()
    fake.setState('open')
    await settle()

    return fake
  }

  it('reports a change only after it has held for the debounce window', async () => {
    const fake = await connected()
    setWindowState({ focused: false })
    window.dispatchEvent(new Event('blur'))
    await vi.advanceTimersByTimeAsync(ATTENTION_DEBOUNCE_MS - 1)

    expect(fake.sent('client.attention')).toHaveLength(0)

    await vi.advanceTimersByTimeAsync(1)

    expect(fake.sent('client.attention')).toEqual([{ state: 'background' }])
  })

  it('sends nothing when the signal returns to the reported state inside the window', async () => {
    const fake = await connected()
    setWindowState({ focused: false })
    window.dispatchEvent(new Event('blur'))
    await vi.advanceTimersByTimeAsync(ATTENTION_DEBOUNCE_MS - 500)
    setWindowState({ focused: true })
    window.dispatchEvent(new Event('focus'))
    await vi.advanceTimersByTimeAsync(ATTENTION_DEBOUNCE_MS * 2)

    expect(fake.sent('client.attention')).toHaveLength(0)
  })

  it('does not repeat an unchanged state', async () => {
    const fake = await connected()
    setWindowState({ focused: false })
    window.dispatchEvent(new Event('blur'))
    await vi.advanceTimersByTimeAsync(ATTENTION_DEBOUNCE_MS)
    document.dispatchEvent(new Event('visibilitychange'))
    window.dispatchEvent(new Event('blur'))
    await vi.advanceTimersByTimeAsync(ATTENTION_DEBOUNCE_MS * 2)

    expect(fake.sent('client.attention')).toHaveLength(1)
  })

  it('reports system idle from the main-process poll', async () => {
    const fake = await connected()
    idle = true
    await vi.advanceTimersByTimeAsync(IDLE_POLL_MS + ATTENTION_DEBOUNCE_MS)

    expect(fake.sent('client.attention')).toEqual([{ state: 'idle' }])
  })

  it('carries the current attention in a hello after a reconnect', async () => {
    const fake = await connected()
    fake.setState('closed')
    setWindowState({ focused: false })
    window.dispatchEvent(new Event('blur'))
    await vi.advanceTimersByTimeAsync(ATTENTION_DEBOUNCE_MS)
    fake.setState('open')
    await settle()

    expect(fake.sent('client.hello').at(-1)?.attention).toBe('background')
    expect(fake.sent('client.attention')).toHaveLength(0)
  })

  it('does not retry in a loop when the server has not recorded the device', async () => {
    const fake = await connected()

    fake.gateway.request = vi.fn(async () => ({ recorded: false })) as unknown as PresenceGateway['request']
    setWindowState({ focused: false })
    window.dispatchEvent(new Event('blur'))
    await vi.advanceTimersByTimeAsync(ATTENTION_DEBOUNCE_MS * 3)

    expect(fake.gateway.request).toHaveBeenCalledTimes(1)
  })
})

describe('reach.offer', () => {
  const offer = (id = 'offer-1', sessionId: null | string = 'session-9') => ({
    body: 'Your report is ready',
    domain: 'cron',
    kind: 'notify',
    offer_id: id,
    session_id: sessionId,
    title: id
  })

  async function connected() {
    const fake = connect()
    fake.setState('open')
    await settle()

    return fake
  }

  it('raises an OS notification while the window is away and reports it shown', async () => {
    const fake = await connected()
    setWindowState({ focused: false })
    fake.emit('reach.offer', offer())
    await settle()

    expect(notify).toHaveBeenCalledWith(
      expect.objectContaining({
        body: 'Your report is ready',
        focusSessionId: 'session-9',
        kind: 'proactive',
        notifyId: 'reach:offer-1',
        title: 'offer-1'
      })
    )
    expect(fake.sent('reach.outcome')).toEqual([{ offer_id: 'offer-1', outcome: 'shown' }])
    expect($notifications.get()).toHaveLength(0)
  })

  it('shows the in-app toast instead of an OS notification while focused', async () => {
    const fake = await connected()
    fake.emit('reach.offer', offer())
    await settle()

    expect(notify).not.toHaveBeenCalled()
    expect($notifications.get().map(item => item.title)).toEqual(['offer-1'])
    expect(fake.sent('reach.outcome')).toEqual([{ offer_id: 'offer-1', outcome: 'shown' }])
  })

  it('reports acted when the OS notification is clicked', async () => {
    const fake = await connected()
    setWindowState({ focused: false })
    fake.emit('reach.offer', offer())
    await settle()
    settleReachOfferNotification('reach:offer-1', 'acted')
    settleReachOfferNotification('reach:offer-1', 'dismissed')

    expect(fake.sent('reach.outcome').map(p => p.outcome)).toEqual(['shown', 'acted'])
  })

  it('reports dismissed when the OS notification is closed', async () => {
    const fake = await connected()
    setWindowState({ focused: false })
    fake.emit('reach.offer', offer())
    await settle()
    settleReachOfferNotification('reach:offer-1', 'dismissed')

    expect(fake.sent('reach.outcome').map(p => p.outcome)).toEqual(['shown', 'dismissed'])
  })

  it('reports acted from the toast action and dismissed from closing it, but not from its own timeout', async () => {
    const fake = await connected()
    fake.emit('reach.offer', offer('offer-act'))
    fake.emit('reach.offer', offer('offer-close'))
    fake.emit('reach.offer', offer('offer-expire'))
    await settle()

    const toast = (title: string) => $notifications.get().find(item => item.title === title)!
    toast('offer-act').action?.onClick()
    dismissNotification(toast('offer-close').id)
    await vi.advanceTimersByTimeAsync(TOAST_LIFETIME_MS)

    expect($notifications.get()).toHaveLength(0)

    expect(
      fake
        .sent('reach.outcome')
        .filter(params => params.outcome !== 'shown')
        .map(params => [params.offer_id, params.outcome])
        .sort()
    ).toEqual([
      ['offer-act', 'acted'],
      ['offer-close', 'dismissed']
    ])
  })

  it('presents each offer id once, however many sockets deliver it', async () => {
    const first = await connected()
    const second = await connected()
    setWindowState({ focused: false })
    first.emit('reach.offer', offer())
    second.emit('reach.offer', offer())
    await settle()

    expect(notify).toHaveBeenCalledTimes(1)
    expect(first.sent('reach.outcome').length + second.sent('reach.outcome').length).toBe(1)
  })

  it('sends nothing when the proactive kind is switched off', async () => {
    const fake = await connected()
    setNativeNotifyKind('proactive', false)
    setWindowState({ focused: false })
    fake.emit('reach.offer', offer())
    await settle()

    expect($nativeNotifyPrefs.get().kinds.proactive).toBe(false)
    expect(notify).not.toHaveBeenCalled()
    expect(fake.sent('reach.outcome')).toHaveLength(0)
  })

  it('sends nothing when the OS declines the notification', async () => {
    const fake = await connected()
    notify.mockResolvedValueOnce(false)
    setWindowState({ focused: false })
    fake.emit('reach.offer', offer())
    await settle()

    expect(fake.sent('reach.outcome')).toHaveLength(0)
  })

  it('ignores a malformed offer', async () => {
    const fake = await connected()
    setWindowState({ focused: false })
    fake.emit('reach.offer', { offer_id: '', title: 'x', body: 'y' })
    fake.emit('reach.offer', undefined)
    await settle()

    expect(notify).not.toHaveBeenCalled()
    expect(fake.sent('reach.outcome')).toHaveLength(0)
  })
})
