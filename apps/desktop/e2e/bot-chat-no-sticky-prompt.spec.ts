import fs from 'node:fs'
import path from 'node:path'

import type { Locator, Page } from '@playwright/test'

import { writeEnvFile, writeMockProviderConfig } from '../../../tests-js/scripts/mock-provider-config'
import { startMockServer } from '../../../tests-js/scripts/mock-server'

import { buildAppEnv, createSandbox, launchDesktop, type MockBackendFixture, waitForAppReady } from './fixtures'
import { RealSessionBuilder } from './real-session-builder'
import { expect, test } from './test'
import { VISUAL_WINDOW_HEIGHT, VISUAL_WINDOW_WIDTH } from './visual-snapshot'

const ARTIFACT_DIR =
  process.env.BOT_NO_STICKY_PROMPT_SCREENSHOT_DIR ??
  path.join(process.cwd(), 'test-results', 'bot-chat-no-sticky-prompt')

const BOT_PROMPT = 'E2E_BOT_STICKY_PROMPT'
const REGULAR_TITLE = 'E2E Regular Sticky Prompt Chat'
const REGULAR_PROMPT = 'E2E_REGULAR_STICKY_PROMPT'
const REPLY_LINE_COUNT = 40
const LAST_REPLY_LINE = `E2E_LONG_REPLY_LINE_${REPLY_LINE_COUNT}`

const LONG_REPLY = Array.from({ length: REPLY_LINE_COUNT }, (_, index) => `E2E_LONG_REPLY_LINE_${index + 1}`).join(
  '\n\n'
)

const SCROLL_TARGET = 600

let fixture: MockBackendFixture | null = null

interface BubbleReading {
  bottom: number
  position: string
  top: number
}

async function capture(page: Page, name: string): Promise<void> {
  fs.mkdirSync(ARTIFACT_DIR, { recursive: true })
  await page.screenshot({ path: path.join(ARTIFACT_DIR, `${name}.png`) })
}

async function scrollViewport(viewport: Locator, top: number): Promise<void> {
  await viewport.evaluate((element, target) => {
    element.scrollTop = target
  }, top)
  await expect.poll(() => viewport.evaluate(element => Math.round(element.scrollTop))).toBe(top)
}

async function readBubble(root: Locator): Promise<BubbleReading> {
  return root.evaluate(element => {
    const viewport = element.closest('[data-slot="aui_thread-viewport"]')

    if (!viewport) {
      throw new Error('user bubble is not inside a thread viewport')
    }

    const bubble = element.getBoundingClientRect()
    const scrollport = viewport.getBoundingClientRect()

    return {
      bottom: bubble.bottom - scrollport.top,
      position: getComputedStyle(element).position,
      top: bubble.top - scrollport.top
    }
  })
}

async function seedLongReplyChat(hermesHome: string, title: string, prompt: string): Promise<void> {
  const builder = await RealSessionBuilder.start(hermesHome)

  try {
    await builder.createSession({ title, turns: [prompt] })
  } finally {
    await builder.close()
  }
}

test.beforeAll(async () => {
  const mock = await startMockServer({ replyForPrompt: () => LONG_REPLY })
  const sandbox = createSandbox('bot-chat-no-sticky-prompt')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)

  await seedLongReplyChat(sandbox.hermesHome, REGULAR_TITLE, REGULAR_PROMPT)

  const botHome = path.join(sandbox.hermesHome, 'profiles', 'alpha')
  fs.mkdirSync(botHome, { recursive: true })
  writeMockProviderConfig(botHome, mock.url)
  writeEnvFile(botHome)
  await seedLongReplyChat(botHome, 'Bot Chat', BOT_PROMPT)

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

test('regular chats keep the user bubble pinned to the top while the reply scrolls', async () => {
  test.setTimeout(180_000)
  const page = fixture!.page

  const toDefault = page.getByRole('button', { name: 'Switch to default' })

  await toDefault.waitFor({ state: 'visible', timeout: 10_000 }).catch(() => undefined)

  if (await toDefault.isVisible()) {
    await toDefault.click()
  }

  await page.locator('[data-slot="sidebar"] button').filter({ hasText: REGULAR_TITLE }).first().click()

  const viewport = page.locator('[data-slot="aui_thread-viewport"]').filter({ visible: true }).first()
  const bubble = viewport.locator('[data-slot="aui_user-message-root"]').first()

  await expect(viewport.getByText(REGULAR_PROMPT, { exact: true })).toBeVisible({ timeout: 60_000 })
  await expect(viewport.getByText(LAST_REPLY_LINE, { exact: true }), 'the long reply finished rendering').toBeAttached({
    timeout: 60_000
  })
  await expect(viewport.locator('.sticky-human-clamp'), 'regular user bubble keeps the two-line clamp').toHaveCount(1)

  await scrollViewport(viewport, 0)
  expect((await readBubble(bubble)).position, 'regular user bubble is sticky at rest').toBe('sticky')

  expect(
    await viewport.evaluate(element => element.scrollHeight - element.clientHeight),
    'regular reply is long enough to scroll past the prompt'
  ).toBeGreaterThan(SCROLL_TARGET)
  await scrollViewport(viewport, SCROLL_TARGET)

  const reading = await readBubble(bubble)
  expect(reading.position, 'regular user bubble is sticky').toBe('sticky')
  expect(reading.top, 'regular user bubble is pinned at the top edge').toBeGreaterThanOrEqual(0)
  expect(reading.top, 'regular user bubble is pinned at the top edge').toBeLessThan(16)
  expect(reading.bottom, 'regular user bubble is still in view').toBeGreaterThan(0)

  await capture(page, 'regular-pinned')
})

test('bot chats let the user bubble scroll out of view instead of pinning it', async () => {
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
  await expect(botSurface).toBeVisible({ timeout: 60_000 })

  const viewport = page.locator('[data-slot="aui_thread-viewport"]').filter({ visible: true }).first()
  const bubble = viewport.locator('[data-slot="aui_user-message-root"]').first()

  await expect(viewport.getByText(BOT_PROMPT, { exact: true })).toBeVisible({ timeout: 60_000 })
  await expect(viewport.getByText(LAST_REPLY_LINE, { exact: true }), 'the long reply finished rendering').toBeAttached({
    timeout: 90_000
  })
  await expect(viewport.locator('.sticky-human-clamp'), 'bot user bubble carries no clamp').toHaveCount(0)

  await scrollViewport(viewport, 0)
  expect((await readBubble(bubble)).position, 'bot user bubble is not sticky at rest').toBe('relative')

  expect(
    await viewport.evaluate(element => element.scrollHeight - element.clientHeight),
    'bot reply is long enough to scroll past the prompt'
  ).toBeGreaterThan(SCROLL_TARGET)
  await scrollViewport(viewport, SCROLL_TARGET)

  const reading = await readBubble(bubble)
  expect(reading.position, 'bot user bubble is not sticky').toBe('relative')
  expect(reading.top, 'bot user bubble is not pinned to the top').toBeLessThan(0)
  expect(reading.bottom, 'bot user bubble has scrolled out of view').toBeLessThanOrEqual(0)

  await capture(page, 'bot-scrolled')
})
