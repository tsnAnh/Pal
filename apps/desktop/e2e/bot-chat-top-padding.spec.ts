import fs from 'node:fs'
import path from 'node:path'

import type { Locator, Page } from '@playwright/test'

import { writeEnvFile, writeMockProviderConfig } from '../../../tests-js/scripts/mock-provider-config'
import { startMockServer } from '../../../tests-js/scripts/mock-server'

import { buildAppEnv, createSandbox, launchDesktop, type MockBackendFixture, waitForAppReady } from './fixtures'
import { RealSessionBuilder } from './real-session-builder'
import { expect, test } from './test'
import { VISUAL_WINDOW_HEIGHT, VISUAL_WINDOW_WIDTH } from './visual-snapshot'

const ARTIFACT_DIR = '/tmp/bot-chat-top-padding'
const BOT_GREETING = 'Hello alpha'
const REGULAR_TITLE = 'Top Padding Regular Chat'
const REGULAR_PROMPT = 'TOP_PADDING_REGULAR_PROMPT'
const CHIP_CLEARANCE_PX = 8

let fixture: MockBackendFixture | null = null

async function capture(page: Page, name: string): Promise<void> {
  fs.mkdirSync(ARTIFACT_DIR, { recursive: true })
  await page.screenshot({ path: path.join(ARTIFACT_DIR, `${name}.png`) })
}

async function boxOf(locator: Locator, label: string): Promise<{ height: number; y: number }> {
  const box = await locator.boundingBox()

  if (!box) {
    throw new Error(`${label} has no layout box`)
  }

  return box
}

test.beforeAll(async () => {
  const mock = await startMockServer()
  const sandbox = createSandbox('bot-chat-top-padding')
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

test('regular chats keep the thread content padding-top', async () => {
  test.setTimeout(180_000)
  const page = fixture!.page

  const toDefault = page.getByRole('button', { name: 'Switch to default' })

  if (await toDefault.isVisible()) {
    await toDefault.click()
  }

  await page.getByRole('button', { name: REGULAR_TITLE, exact: true }).filter({ visible: true }).first().click()

  const regularSurface = page.locator('[data-chat-surface]:not([data-bot-chat])').filter({ visible: true }).first()
  await expect(regularSurface.getByText(REGULAR_PROMPT, { exact: true })).toBeVisible({ timeout: 60_000 })

  const { actual, expected } = await regularSurface.locator('[data-slot="aui_thread-content"]').evaluate(el => {
    const probe = document.createElement('div')
    probe.style.paddingTop = 'calc(var(--titlebar-height) - 0.5rem)'
    el.append(probe)
    const expectedPaddingTop = getComputedStyle(probe).paddingTop
    probe.remove()

    return { actual: getComputedStyle(el).paddingTop, expected: expectedPaddingTop }
  })

  expect(actual, 'regular chat thread keeps its titlebar-based padding-top').toBe(expected)

  await capture(page, 'regular-chat')
})

test('bot chat messages start below the header chip at scroll top', async () => {
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

  const botSurface = page.locator('[data-chat-surface][data-bot-chat]').filter({ visible: true }).first()
  await expect(botSurface.getByText(BOT_GREETING, { exact: true })).toBeVisible({ timeout: 60_000 })

  await botSurface.locator('[data-slot="aui_thread-viewport"]').evaluate(el => {
    el.scrollTop = 0
  })

  const chip = botSurface.locator('[data-slot="bot-title-chip"]')
  await expect(chip).toBeVisible()

  const firstMessage = botSurface.locator('[data-slot="aui_thread-content"] [data-bubble="user"]').first()
  await expect(firstMessage).toBeVisible()

  const chipBox = await boxOf(chip, 'bot header chip')
  const messageBox = await boxOf(firstMessage, 'first bot message')

  expect(
    messageBox.y - (chipBox.y + chipBox.height),
    `first message top is at least ${CHIP_CLEARANCE_PX}px below the chip bottom`
  ).toBeGreaterThanOrEqual(CHIP_CLEARANCE_PX)

  await capture(page, 'bot-chat')
})
