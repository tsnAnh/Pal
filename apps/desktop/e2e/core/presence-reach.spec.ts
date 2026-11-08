import * as fs from 'node:fs'
import * as path from 'node:path'
import { DatabaseSync } from 'node:sqlite'

import { type ElectronApplication, expect, type Page, test } from '@playwright/test'

import {
  coreAppEnv,
  type CoreSandbox,
  createCoreSandbox,
  launchCoreApp,
  recordWebSockets,
  waitForInteractive,
  writeProviderHome,
  type WsRecorder
} from './harness'
import { startScriptedProvider } from './provider'

const nonce = Math.random()
  .toString(36)
  .slice(2, 8)
  .replace(/[^a-z0-9]/g, 'x')
  .padEnd(4, 'q')

const U = (n: number) => `U${n}-reach${nonce}`
const A = (n: number) => `A${n}-reach${nonce}`

const ALWAYS_REACHABLE = `proactive:
  quiet_hours:
    start: "00:00"
    end: "00:00"
`

interface NotifyPayload {
  kind?: string
  notifyId?: string
  tag?: string
  title?: string
  body?: string
  focusSessionId?: string
}

async function recordNotifyIpc(app: ElectronApplication): Promise<void> {
  await app.evaluate(({ ipcMain }) => {
    const calls: unknown[] = []

    ;(globalThis as { __notifyCalls?: unknown[] }).__notifyCalls = calls
    ipcMain.removeHandler('hermes:notify')
    ipcMain.handle('hermes:notify', async (_event, payload) => {
      calls.push(payload)

      return true
    })
  })
}

const notifyCalls = (app: ElectronApplication): Promise<NotifyPayload[]> =>
  app.evaluate(() => (globalThis as { __notifyCalls?: NotifyPayload[] }).__notifyCalls ?? [])

async function simulateNotificationClick(app: ElectronApplication, notifyId: string): Promise<void> {
  await app.evaluate(({ BrowserWindow }, id) => {
    for (const win of BrowserWindow.getAllWindows()) {
      win.webContents.send('hermes:notification-activate', { notifyId: id })
    }
  }, notifyId)
}

async function windowGoesAway(page: Page): Promise<void> {
  await page.evaluate(() => {
    document.hasFocus = () => false
    window.dispatchEvent(new Event('blur'))
  })
}

const sentFrames = (ws: WsRecorder, method: string) => ws.sent.filter(frame => frame.method === method)

function reachOfferRow(sandbox: CoreSandbox, offerId: string) {
  const dbPath = path.join(sandbox.hermesHome, 'state.db')

  if (!fs.existsSync(dbPath)) {
    return null
  }

  const db = new DatabaseSync(dbPath, { readOnly: true })

  try {
    return (
      (db.prepare('SELECT outcome, outcome_device FROM reach_offers WHERE offer_id = ?').get(offerId) as
        | undefined
        | { outcome: null | string; outcome_device: null | string }) ?? null
    )
  } catch {
    return null
  } finally {
    db.close()
  }
}

test('desktop declares itself to the gateway and presents a proactive offer end to end', async () => {
  test.setTimeout(420_000)
  const provider = await startScriptedProvider()
  const sandbox = createCoreSandbox('reach')
  writeProviderHome(sandbox.hermesHome, provider.url, ALWAYS_REACHABLE)
  const { app, page } = await launchCoreApp(coreAppEnv(sandbox))
  const ws = recordWebSockets(page)

  try {
    await waitForInteractive(app, page)
    await recordNotifyIpc(app)

    const identity = await test.step('hello: a desktop device is declared after connect', async () => {
      await expect.poll(() => sentFrames(ws, 'client.hello').length, { message: 'client.hello sent' }).toBeGreaterThan(0)

      const methods = ws.sent.map(frame => frame.method)
      expect(methods.indexOf('runtime.describe')).toBeGreaterThanOrEqual(0)
      expect(methods.indexOf('runtime.describe')).toBeLessThan(methods.indexOf('client.hello'))

      const hello = sentFrames(ws, 'client.hello')[0].params

      expect(hello).toMatchObject({ accepts_offers: true, kind: 'desktop' })
      expect(hello.device_id).toMatch(/^[A-Za-z0-9-]{8,64}$/)
      expect(hello.label).toMatch(/^Desktop \((macOS|Windows|Linux)\)$/)
      expect(typeof hello.app_version).toBe('string')
      expect(['foreground', 'background']).toContain(hello.attention)

      const persisted = JSON.parse(fs.readFileSync(path.join(sandbox.userDataDir, 'reach-device.json'), 'utf8'))
      expect(persisted.deviceId).toBe(hello.device_id)

      return hello as { device_id: string }
    })

    await test.step('attention: leaving the window is reported once, debounced', async () => {
      await windowGoesAway(page)
      await expect
        .poll(() => sentFrames(ws, 'client.attention').map(frame => frame.params.state), {
          message: 'client.attention background'
        })
        .toEqual(['background'])
    })

    const offerId = await test.step('offer: a real user cron job with deliver=active reaches the desktop', async () => {
      provider.script(U(1), [{ text: [`${A(1)} `, 'nightly ', 'report ', 'ready'] }])
      const runAt = new Date(Date.now() + 3000).toISOString().replace(/\.\d+Z$/, '+00:00')

      await page.evaluate(
        async body => {
          await (window as any).hermesDesktop.api({ body, method: 'POST', path: '/api/cron/jobs' })
        },
        { deliver: 'active', name: `reach-${nonce}`, prompt: `${U(1)} write the nightly report`, schedule: runAt }
      )

      await expect
        .poll(() => ws.events.find(event => event.type === 'reach.offer')?.payload?.offer_id ?? '', {
          message: 'reach.offer frame from the gateway',
          timeout: 240_000
        })
        .not.toBe('')

      return String(ws.events.find(event => event.type === 'reach.offer')!.payload.offer_id)
    })

    await test.step('notify: the offer becomes a proactive OS notification and reports shown', async () => {
      await expect
        .poll(async () => (await notifyCalls(app)).filter(call => call.kind === 'proactive').length, {
          message: 'hermes:notify with kind proactive'
        })
        .toBe(1)

      const [call] = (await notifyCalls(app)).filter(note => note.kind === 'proactive')
      expect(call.tag).toBe(offerId)
      expect(call.notifyId).toBeTruthy()

      await expect
        .poll(() => sentFrames(ws, 'reach.outcome').map(frame => [frame.params.offer_id, frame.params.outcome]), {
          message: 'reach.outcome shown'
        })
        .toEqual([[offerId, 'shown']])
    })

    await test.step('click: acting on the notification reports acted to the gateway', async () => {
      const [call] = (await notifyCalls(app)).filter(note => note.kind === 'proactive')
      await simulateNotificationClick(app, call.notifyId!)

      await expect
        .poll(() => sentFrames(ws, 'reach.outcome').map(frame => frame.params.outcome), {
          message: 'reach.outcome acted'
        })
        .toEqual(['shown', 'acted'])

      await expect
        .poll(() => reachOfferRow(sandbox, offerId)?.outcome ?? null, { message: 'gateway recorded the outcome' })
        .toBe('acted')
      expect(reachOfferRow(sandbox, offerId)?.outcome_device).toBe(identity.device_id)
    })
  } finally {
    await app.close().catch(() => undefined)
    await provider.close()
    sandbox.cleanup()
  }
})
