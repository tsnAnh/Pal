import fs from 'node:fs'
import path from 'node:path'

import type { Page } from '@playwright/test'

import { writeEnvFile, writeMockProviderConfig } from '../../../tests-js/scripts/mock-provider-config'
import { startMockServer } from '../../../tests-js/scripts/mock-server'

import { buildAppEnv, createSandbox, launchDesktop, type MockBackendFixture, waitForAppReady } from './fixtures'
import { RealSessionBuilder } from './real-session-builder'
import { expect, test } from './test'
import { VISUAL_WINDOW_HEIGHT, VISUAL_WINDOW_WIDTH } from './visual-snapshot'

const ARTIFACT_DIR =
  process.env.AGENT_DELIVERY_MASCOT_SCREENSHOT_DIR ?? path.join(process.cwd(), 'test-results', 'agent-delivery-mascot')

const OUTBOUND_TURN = `E2E_CALL(terminal)[{"command":"echo hermes -p beta chat -q 'Message from alpha: ship the report'"}]`
const INBOUND_TURN = 'Message from 🤖 gamma (@gamma): the report is ready for review'

let fixture: MockBackendFixture | null = null

async function capture(page: Page, name: string): Promise<void> {
  fs.mkdirSync(ARTIFACT_DIR, { recursive: true })
  await page.screenshot({ path: path.join(ARTIFACT_DIR, `${name}.png`) })
}

async function seedBot(hermesHome: string, mockUrl: string, name: string, turns: readonly string[]): Promise<void> {
  const dir = path.join(hermesHome, 'profiles', name)
  fs.mkdirSync(dir, { recursive: true })
  writeMockProviderConfig(dir, mockUrl)
  writeEnvFile(dir)

  const builder = await RealSessionBuilder.start(dir)

  try {
    await builder.createSession({ title: 'Bot Chat', turns })
  } finally {
    await builder.close()
  }
}

test.beforeAll(async () => {
  const mock = await startMockServer()
  const sandbox = createSandbox('agent-delivery-mascot')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)

  await seedBot(sandbox.hermesHome, mock.url, 'alpha', [OUTBOUND_TURN, INBOUND_TURN])
  await seedBot(sandbox.hermesHome, mock.url, 'beta', ['Hello beta'])
  await seedBot(sandbox.hermesHome, mock.url, 'gamma', ['Hello gamma'])

  const { app, page } = await launchDesktop(buildAppEnv(sandbox))

  await app.evaluate(
    ({ BrowserWindow }, size) => {
      BrowserWindow.getAllWindows()[0]?.setBounds({ x: 0, y: 0, ...size })
    },
    { width: Math.max(VISUAL_WINDOW_WIDTH, 1400), height: VISUAL_WINDOW_HEIGHT }
  )

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

test('delivery notices carry the bot mascot and no disclosure', async () => {
  test.setTimeout(300_000)
  const page = fixture!.page

  await page
    .getByRole('button', { name: 'Bots', exact: true })
    .or(page.getByRole('tab', { name: 'Bots', exact: true }))
    .first()
    .click()

  const row = page.locator('[data-slot="bots-roster"] [data-roster-key="local::alpha"]')
  await expect(row).toBeVisible({ timeout: 30_000 })
  await row.click()

  const surface = page.locator('[data-chat-surface][data-bot-chat]').filter({ visible: true }).first()
  await expect(surface).toBeVisible({ timeout: 60_000 })

  const outbound = surface.locator('[data-slot="aui_agent-delivery-notice"]')
  const reply = surface.locator('[data-slot="aui_agent-reply-notice"]')
  const inbound = surface.locator('[data-slot="aui_agent-message-note"]')

  await expect(outbound, 'outbound delivery renders as a notice').toHaveCount(1, { timeout: 90_000 })
  await expect(reply, 'the recipient reply renders as a notice').toHaveCount(1)

  const peerRun = surface.getByRole('button', { name: /messages? with gamma/ })
  await expect(
    peerRun.locator('svg[data-bot-face="gamma"]'),
    'the folded peer run shows the gamma mascot'
  ).toBeVisible()
  await peerRun.click()
  await expect(inbound, 'the inbound agent message renders as a notice').toHaveCount(1)

  for (const [label, notice, bot] of [
    ['Messaged', outbound, 'beta'],
    ['Message from (reply)', reply, 'beta'],
    ['Message from (inbound)', inbound, 'gamma']
  ] as const) {
    await expect(notice.locator(`svg[data-bot-face="${bot}"]`), `${label} shows the ${bot} mascot`).toBeVisible()
    await expect(notice, `${label} has no robot emoji`).not.toContainText('🤖')
  }

  await expect(outbound).toContainText('Messaged beta')
  await expect(reply).toContainText('Message from beta')
  await expect(inbound).toContainText('Message from gamma')

  await expect(surface.getByText('show message'), 'the message body disclosure is gone').toHaveCount(0)
  await expect(
    surface
      .locator(
        '[data-slot="aui_agent-delivery-notice"], [data-slot="aui_agent-reply-notice"], [data-slot="aui_agent-message-note"]'
      )
      .locator('details'),
    'no disclosure element inside the notices'
  ).toHaveCount(0)
  await capture(page, 'notices')
})
