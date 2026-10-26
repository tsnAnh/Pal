import fs from 'node:fs'
import path from 'node:path'

import type { Page } from '@playwright/test'

import { writeEnvFile, writeMockProviderConfig } from '../../../tests-js/scripts/mock-provider-config'
import { startMockServer } from '../../../tests-js/scripts/mock-server'

import { buildAppEnv, createSandbox, launchDesktop, type MockBackendFixture, waitForAppReady } from './fixtures'
import { RealSessionBuilder } from './real-session-builder'
import { expect, test } from './test'
import { VISUAL_WINDOW_HEIGHT, VISUAL_WINDOW_WIDTH } from './visual-snapshot'

const ARTIFACT_DIR = '/tmp/bot-chat-header-chip'

let fixture: MockBackendFixture | null = null

async function capture(page: Page, name: string): Promise<void> {
  fs.mkdirSync(ARTIFACT_DIR, { recursive: true })
  await page.screenshot({ path: path.join(ARTIFACT_DIR, `${name}.png`) })
}

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
  const mock = await startMockServer()
  const sandbox = createSandbox('bot-chat-header-chip')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)

  await seedBot(sandbox.hermesHome, mock.url, 'alpha')

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

test('bot chat header chip shows the bot name alone, with no chevron and no profile button', async () => {
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
  await expect(page.getByText('Hello alpha', { exact: true }).filter({ visible: true }).first()).toBeVisible({
    timeout: 60_000
  })

  const chip = page.locator('[data-slot="bot-title-chip"]').filter({ visible: true }).first()
  await expect(chip, 'header chip is visible in the bot chat').toBeVisible({ timeout: 30_000 })
  await expect(chip, 'header chip names the bot').toContainText(/alpha/i)

  await expect(
    chip.locator('.codicon-chevron-down, [class*="chevron"]'),
    'header chip carries no chevron icon'
  ).toHaveCount(0)
  await expect(chip.locator('xpath=./*'), 'header chip holds only the face and the name').toHaveCount(2)

  const chipGroup = chip.locator('xpath=..')
  await expect(chipGroup.getByRole('button'), 'no button sits beside the header chip').toHaveCount(1)
  await expect(page.locator('[data-slot="bot-profile-reopen"]'), 'circular profile button is gone').toHaveCount(0)

  const box = (await chip.boundingBox())!
  await capture(page, 'bot-chat-header')
  await page.screenshot({
    clip: {
      height: box.height + 48,
      width: box.width + 320,
      x: Math.max(0, box.x - 160),
      y: Math.max(0, box.y - 24)
    },
    path: path.join(ARTIFACT_DIR, 'bot-chat-header-chip.png')
  })

  await chip.click()
  const menu = page.getByRole('menu').filter({ visible: true }).first()
  await expect(menu, 'header chip still opens the session actions menu').toBeVisible({ timeout: 10_000 })
  await page.keyboard.press('Escape')
  await expect(menu).toBeHidden({ timeout: 10_000 })
})
