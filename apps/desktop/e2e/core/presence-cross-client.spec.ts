import * as fs from 'node:fs'
import * as path from 'node:path'

import { type ElectronApplication, expect, type Page, test } from '@playwright/test'

import {
  coreAppEnv,
  createCoreSandbox,
  launchCoreApp,
  recordWebSockets,
  send,
  waitForInteractive,
  type WsRecorder
} from './harness'

const CONTROL = process.env.HERMES_PRESENCE_E2E_CTL ?? ''
const GATEWAY_HOME = process.env.HERMES_PRESENCE_E2E_HOME ?? ''
const PROFILE = process.env.HERMES_PRESENCE_E2E_PROFILE ?? 'bot-alpha'
const ARTIFACTS = process.env.HERMES_PRESENCE_E2E_ARTIFACTS ?? ''
const COMMAND_FILE = path.join(CONTROL, 'desktop.cmd')
const ACK_FILE = path.join(CONTROL, 'desktop.ack')
const READY_FILE = path.join(CONTROL, 'desktop.ready')

interface Command {
  id: string
  op: 'away' | 'expect-offer' | 'quit' | 'send'
  text?: string
  title?: string
}

interface NotifyPayload {
  kind?: string
  notifyId?: string
  tag?: string
  title?: string
  body?: string
}

type Verdict = { data?: Record<string, unknown>; ok: boolean }

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

const framesSent = (ws: WsRecorder, method: string) => ws.sent.filter(frame => frame.method === method)

const offerEvents = (ws: WsRecorder) => ws.events.filter(event => event.type === 'reach.offer')

function readCommand(): Command | null {
  if (!fs.existsSync(COMMAND_FILE)) {
    return null
  }

  try {
    const command = JSON.parse(fs.readFileSync(COMMAND_FILE, 'utf8')) as Command
    fs.rmSync(COMMAND_FILE, { force: true })

    return command
  } catch {
    return null
  }
}

async function nextCommand(): Promise<Command> {
  let found: Command | null = null

  await expect
    .poll(
      () => {
        found = readCommand()

        return found !== null
      },
      { intervals: [200], message: 'a command from the orchestrator', timeout: 1_200_000 }
    )
    .toBe(true)

  return found!
}

function acknowledge(id: string, verdict: Verdict): void {
  const staged = `${ACK_FILE}.tmp`
  fs.writeFileSync(staged, JSON.stringify({ id, ...verdict }))
  fs.renameSync(staged, ACK_FILE)
}

async function windowGoesAway(page: Page, ws: WsRecorder): Promise<Verdict> {
  const before = framesSent(ws, 'client.attention').length

  await page.evaluate(() => {
    document.hasFocus = () => false
    window.dispatchEvent(new Event('blur'))
  })
  await expect
    .poll(
      () =>
        framesSent(ws, 'client.attention')
          .slice(before)
          .map(frame => frame.params.state),
      {
        message: 'client.attention background',
        timeout: 30_000
      }
    )
    .toContain('background')

  return { ok: true }
}

async function openBotChat(page: Page, profile: string): Promise<void> {
  await page
    .getByRole('button', { name: 'Bots', exact: true })
    .or(page.getByRole('tab', { name: 'Bots', exact: true }))
    .first()
    .click()
  await page.locator(`[data-slot="bots-roster"] [data-roster-key$="::${profile}"]`).first().click()
  await expect(
    page.locator('[data-slot="composer-root"] [contenteditable="true"]').filter({ visible: true }).first()
  ).toBeVisible({
    timeout: 90_000
  })
}

async function sendTurn(page: Page, ws: WsRecorder, text: string): Promise<Verdict> {
  const before = ws.events.filter(event => event.type === 'message.complete').length
  await send(page, text, 'Enter', ws)
  await expect
    .poll(() => ws.events.filter(event => event.type === 'message.complete').length, {
      message: `reply to ${text}`,
      timeout: 120_000
    })
    .toBeGreaterThan(before)

  const submit = framesSent(ws, 'prompt.submit').find(frame => JSON.stringify(frame.params ?? '').includes(text))

  return {
    data: { session_id: submit?.params?.session_id ?? null, profile: submit?.params?.profile ?? null },
    ok: true
  }
}

async function expectOffer(app: ElectronApplication, ws: WsRecorder, title: string): Promise<Verdict> {
  const arrived = () => offerEvents(ws).find(event => event.payload?.title === title)

  await expect.poll(() => Boolean(arrived()), { message: `reach.offer ${title}`, timeout: 240_000 }).toBe(true)
  const offerId = String(arrived()!.payload.offer_id)

  await expect
    .poll(
      async () => (await notifyCalls(app)).filter(call => call.kind === 'proactive' && call.tag === offerId).length,
      {
        message: 'hermes:notify with kind proactive'
      }
    )
    .toBe(1)
  await expect
    .poll(() => framesSent(ws, 'reach.outcome').map(frame => [frame.params.offer_id, frame.params.outcome]), {
      message: 'reach.outcome shown'
    })
    .toContainEqual([offerId, 'shown'])

  const [call] = (await notifyCalls(app)).filter(note => note.kind === 'proactive' && note.tag === offerId)

  return { data: { offer_id: offerId, notify: { kind: call?.kind, tag: call?.tag, title: call?.title } }, ok: true }
}

function writeEvidence(ws: WsRecorder, notifies: NotifyPayload[], diagnostics: string[]): void {
  if (!ARTIFACTS) {
    return
  }

  fs.mkdirSync(ARTIFACTS, { recursive: true })
  fs.writeFileSync(
    path.join(ARTIFACTS, 'desktop-evidence.json'),
    JSON.stringify(
      {
        hello: framesSent(ws, 'client.hello').map(frame => frame.params),
        attention: framesSent(ws, 'client.attention').map(frame => frame.params),
        outcomes: framesSent(ws, 'reach.outcome').map(frame => frame.params),
        offers: offerEvents(ws).map(event => event.payload),
        notifications: notifies,
        diagnostics
      },
      null,
      2
    )
  )
}

test('the real Desktop and the real iPhone app share one Bot Chat and one proactive reach', async () => {
  test.skip(!CONTROL || !GATEWAY_HOME, 'driven by apps/ios/Scripts/e2e-presence')
  test.setTimeout(1_500_000)

  const sandbox = createCoreSandbox('presence-cross')

  const { app, page } = await launchCoreApp(coreAppEnv(sandbox, { HERMES_HOME: GATEWAY_HOME }))

  const ws = recordWebSockets(page)
  const diagnostics: string[] = []

  page.on('console', message => {
    if (message.type() === 'error') {
      diagnostics.push(`console: ${message.text().slice(0, 400)}`)
    }
  })
  page.on('websocket', socket => {
    socket.on('framereceived', frame => {
      const text = String(frame.payload)

      if (text.includes('"error"')) {
        diagnostics.push(`ws: ${text.slice(0, 400)}`)
      }
    })
  })

  let quit = false

  const handlers: Record<Command['op'], (command: Command) => Promise<Verdict>> = {
    away: () => windowGoesAway(page, ws),
    'expect-offer': command => expectOffer(app, ws, command.title ?? ''),
    quit: async () => {
      writeEvidence(ws, await notifyCalls(app).catch(() => []), diagnostics)
      await app.close()
      quit = true

      return { ok: true }
    },
    send: command => sendTurn(page, ws, command.text ?? '')
  }

  try {
    await page.reload()
    await waitForInteractive(app, page)
    await recordNotifyIpc(app)
    await expect.poll(() => framesSent(ws, 'client.hello').length, { message: 'client.hello sent' }).toBeGreaterThan(0)
    await openBotChat(page, PROFILE)
    fs.writeFileSync(READY_FILE, JSON.stringify(framesSent(ws, 'client.hello')[0]?.params ?? {}))

    while (!quit) {
      const command = await nextCommand()
      let verdict: Verdict

      try {
        verdict = await handlers[command.op](command)
      } catch (error) {
        verdict = { data: { error: String(error) }, ok: false }

        if (ARTIFACTS) {
          fs.mkdirSync(ARTIFACTS, { recursive: true })
          await page
            .screenshot({ path: path.join(ARTIFACTS, `desktop-error-${command.op}.png`) })
            .catch(() => undefined)
        }
      }

      acknowledge(command.id, verdict)
    }
  } finally {
    if (!quit) {
      writeEvidence(ws, await notifyCalls(app).catch(() => []), diagnostics)
      await app.close().catch(() => undefined)
    }

    sandbox.cleanup()
  }
})
