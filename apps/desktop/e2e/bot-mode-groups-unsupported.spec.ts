import fs from 'node:fs'
import path from 'node:path'

import { writeEnvFile, writeMockProviderConfig } from '../../../tests-js/scripts/mock-provider-config'
import { startMockServer } from '../../../tests-js/scripts/mock-server'

import { buildAppEnv, createSandbox, launchDesktop, type MockBackendFixture, waitForAppReady } from './fixtures'
import { RealSessionBuilder } from './real-session-builder'
import { expect, test } from './test'
import { VISUAL_WINDOW_HEIGHT, VISUAL_WINDOW_WIDTH } from './visual-snapshot'

const ARTIFACT_DIR = process.env.BOT_GROUPS_UNSUPPORTED_DIR ?? '/tmp/grok-parity/screens/groups-unsupported'

let fixture: MockBackendFixture | null = null

async function seedBot(hermesHome: string, mockUrl: string, name: string): Promise<void> {
  const dir = path.join(hermesHome, 'profiles', name)
  fs.mkdirSync(dir, { recursive: true })
  writeMockProviderConfig(dir, mockUrl)
  writeEnvFile(dir)

  const builder = await RealSessionBuilder.start(dir)

  try {
    await builder.createSession({ title: 'Bot Chat', turns: [`Hello ${name}`] })
  } finally {
    await builder.close()
  }
}

test.beforeAll(async () => {
  test.setTimeout(300_000)
  const mock = await startMockServer({})
  const sandbox = createSandbox('bot-mode-groups-unsupported')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)
  await seedBot(sandbox.hermesHome, mock.url, 'alpha')

  const { app, page } = await launchDesktop(buildAppEnv(sandbox))

  await app.evaluate(({ BrowserWindow }, size) => {
    BrowserWindow.getAllWindows()[0]?.setBounds({ x: 0, y: 0, ...size })
  }, { height: VISUAL_WINDOW_HEIGHT, width: Math.max(VISUAL_WINDOW_WIDTH, 1400) })

  fixture = {
    app,
    page,
    mock,
    mockUrl: mock.url,
    sandbox,
    cleanup: async () => {
      await app.close().catch(() => undefined)
      await mock.close()
      sandbox.cleanup()
    }
  }
  await waitForAppReady(fixture, 120_000)
})

test.afterAll(async () => {
  await fixture?.cleanup()
  fixture = null
})

test('a connected gateway without canonical groups shows no unreachable notice or Retry control', async () => {
  test.setTimeout(300_000)
  const page = fixture!.page

  await page.addInitScript(() => {
    const flags = window as unknown as { __groupsRefused: number }
    const nativeSend = WebSocket.prototype.send

    flags.__groupsRefused = 0

    WebSocket.prototype.send = function send(this: WebSocket, data: Parameters<WebSocket['send']>[0]) {
      const frame = typeof data === 'string' ? (JSON.parse(data) as { id?: number | string; method?: string }) : null

      if (frame?.id !== undefined && frame.method?.startsWith('groups.')) {
        flags.__groupsRefused += 1
        const reply = JSON.stringify({ jsonrpc: '2.0', id: frame.id, error: { code: -32601, message: 'Method not found' } })

        setTimeout(() => this.dispatchEvent(new MessageEvent('message', { data: reply })), 0)

        return
      }

      nativeSend.call(this, data)
    }
  })
  await page.reload()
  await waitForAppReady(fixture!, 120_000)

  await page
    .getByRole('button', { name: 'Bots', exact: true })
    .or(page.getByRole('tab', { name: 'Bots', exact: true }))
    .first()
    .click()
  await expect(page.locator('[data-slot="bots-roster"] [data-roster-key="local::alpha"]')).toBeVisible({
    timeout: 30_000
  })

  await expect
    .poll(() => page.evaluate(() => (window as unknown as { __groupsRefused: number }).__groupsRefused), {
      message: 'the gateway refused groups.* with method-not-found',
      timeout: 30_000
    })
    .toBeGreaterThan(0)
  await page.waitForTimeout(1500)

  await expect(page.getByText("Can't reach Hermes").filter({ visible: true })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Retry', exact: true }).filter({ visible: true })).toHaveCount(0)

  fs.mkdirSync(ARTIFACT_DIR, { recursive: true })
  await page.screenshot({ path: path.join(ARTIFACT_DIR, 'groups-unsupported.png') })
})
