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
  process.env.BOT_STATUSBAR_SCREENSHOT_DIR ?? path.join(process.cwd(), 'test-results', 'bot-mode-statusbar')

const REGULAR_TITLE = 'E2E Regular Statusbar Chat'
const REGULAR_PROMPT = 'E2E_REGULAR_STATUSBAR_PROMPT'
const BOT_GREETING = 'Hello alpha'

let fixture: MockBackendFixture | null = null

async function capture(page: Page, name: string): Promise<void> {
  fs.mkdirSync(ARTIFACT_DIR, { recursive: true })
  await page.screenshot({ path: path.join(ARTIFACT_DIR, `${name}.png`) })
}

async function openRegularChat(page: Page): Promise<void> {
  const toDefault = page.getByRole('button', { name: 'Switch to default' })

  if (await toDefault.waitFor({ state: 'visible', timeout: 15_000 }).then(() => true, () => false)) {
    await toDefault.click()
  }

  await page
    .getByRole('group', { name: 'Sidebar panes' })
    .getByRole('button', { name: 'Sessions', exact: true })
    .click()
  await page.locator('[data-slot="sidebar"] button').filter({ hasText: REGULAR_TITLE }).first().click()
  await expect(
    page.locator('[data-chat-surface]:not([data-bot-chat])').filter({ visible: true }).first()
  ).toContainText(REGULAR_PROMPT, { timeout: 60_000 })
}

async function leaveBotSurface(page: Page): Promise<void> {
  await page.locator('[data-slot="account-pill"]').filter({ visible: true }).click()
  await page
    .locator('[data-slot="account-menu"]')
    .getByRole('menuitem', { name: /^Sidebar panes/ })
    .click()
  await page.getByRole('menuitemradio', { name: 'Sessions', exact: true }).click()
  await page.locator('[data-slot="sidebar"] button').filter({ hasText: REGULAR_TITLE }).first().click()
  await expect(
    page.locator('[data-chat-surface]:not([data-bot-chat])').filter({ visible: true }).first()
  ).toContainText(REGULAR_PROMPT, { timeout: 60_000 })
}

async function openBotChat(page: Page): Promise<void> {
  await page
    .getByRole('button', { name: 'Bots', exact: true })
    .or(page.getByRole('tab', { name: 'Bots', exact: true }))
    .first()
    .click()

  const row = page.locator('[data-slot="bots-roster"] [data-roster-key="local::alpha"]')
  await expect(row).toBeVisible({ timeout: 30_000 })
  await row.click()
  await expect(page.locator('[data-chat-surface][data-bot-chat]').filter({ visible: true }).first()).toContainText(
    BOT_GREETING,
    { timeout: 60_000 }
  )
}

test.beforeAll(async () => {
  const mock = await startMockServer()
  const sandbox = createSandbox('bot-mode-statusbar')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)

  const regular = await RealSessionBuilder.start(sandbox.hermesHome)

  try {
    await regular.createSession({ title: REGULAR_TITLE, turns: [REGULAR_PROMPT] })
  } finally {
    await regular.close()
  }

  const botHome = path.join(sandbox.hermesHome, 'profiles', 'alpha')
  fs.mkdirSync(botHome, { recursive: true })
  writeMockProviderConfig(botHome, mock.url)
  writeEnvFile(botHome)

  const bot = await RealSessionBuilder.start(botHome)

  try {
    await bot.createSession({ title: 'Bot Chat', turns: [BOT_GREETING] })
  } finally {
    await bot.close()
  }

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

test('statusbar follows the chat: shown in regular chats, gone in bot chats and bots-only mode', async () => {
  test.setTimeout(300_000)
  const page = fixture!.page
  const statusbar = page.locator('[data-slot="statusbar"]')

  await openRegularChat(page)
  await expect(statusbar, 'regular chat keeps the statusbar').toBeVisible({ timeout: 30_000 })
  await capture(page, 'regular-chat')

  await openBotChat(page)
  await expect(statusbar, 'bot chat has no statusbar').toHaveCount(0)

  const footer = await page.evaluate(() => {
    const bottom = (selector: string) => {
      const box = [...document.querySelectorAll(selector)]
        .map(el => el.getBoundingClientRect())
        .find(rect => rect.width > 0 && rect.height > 0)

      return box ? box.bottom : null
    }

    return {
      chat: bottom('[data-chat-surface][data-bot-chat]'),
      composer: bottom('[data-chat-surface][data-bot-chat] [data-slot="composer-root"]'),
      roster: bottom('[data-bots-pane]'),
      shell: bottom('[data-contrib-shell]'),
      viewport: window.innerHeight
    }
  })

  expect(footer.chat, 'chat surface reaches the window bottom').toBeCloseTo(footer.viewport, 0)
  expect(footer.roster, 'roster pane reaches the window bottom').toBeCloseTo(footer.viewport, 0)
  expect(footer.shell, 'shell reaches the window bottom').toBeCloseTo(footer.viewport, 0)
  expect(footer.viewport - footer.composer!, 'composer keeps an even bottom inset with no leftover strip').toBeLessThanOrEqual(
    24
  )
  await capture(page, 'bot-chat')

  const newMenu = page.getByRole('button', { name: 'New bot or group chat' }).filter({ visible: true }).first()
  await newMenu.click()
  await page.getByRole('menuitem', { name: 'Bots-only mode' }).click()
  await expect(statusbar, 'bots-only mode has no statusbar').toHaveCount(0)
  await capture(page, 'bots-only')

  await newMenu.click()
  await page.getByRole('menuitem', { name: 'Show sessions' }).click()
  await leaveBotSurface(page)
  await expect(statusbar, 'leaving bot surfaces restores the statusbar preference').toBeVisible({ timeout: 30_000 })
})
