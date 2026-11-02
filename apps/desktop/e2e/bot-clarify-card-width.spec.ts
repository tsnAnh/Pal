import fs from 'node:fs'
import path from 'node:path'

import type { Page } from '@playwright/test'

import { writeEnvFile, writeMockProviderConfig } from '../../../tests-js/scripts/mock-provider-config'
import { startMockServer, WIDE_CLARIFY_QUESTIONS, WIDE_CLARIFY_TRIGGER } from '../../../tests-js/scripts/mock-server'

import { buildAppEnv, createSandbox, launchDesktop, type MockBackendFixture, waitForAppReady } from './fixtures'
import { RealSessionBuilder } from './real-session-builder'
import { expect, test } from './test'
import { VISUAL_WINDOW_HEIGHT } from './visual-snapshot'

const ARTIFACT_DIR =
  process.env.CLARIFY_WIDTH_SCREENSHOT_DIR ?? path.join(process.cwd(), 'test-results', 'bot-clarify-card-width')

const READABLE_MAX_PX = 552
const AVATAR_GUTTER_PX = 34

let fixture: MockBackendFixture | null = null

async function capture(page: Page, name: string): Promise<void> {
  fs.mkdirSync(ARTIFACT_DIR, { recursive: true })
  await page.screenshot({ animations: 'disabled', caret: 'hide', path: path.join(ARTIFACT_DIR, `${name}.png`) })
}

async function resizeWindow(width: number): Promise<void> {
  await fixture!.app.evaluate(
    ({ BrowserWindow }, size) => {
      const win = BrowserWindow.getAllWindows()[0]

      win?.unmaximize()
      win?.setMinimumSize(1, 1)
      win?.setBounds({ x: 0, y: 0, ...size })
    },
    { height: VISUAL_WINDOW_HEIGHT, width }
  )
}

test.beforeAll(async () => {
  test.setTimeout(240_000)
  const mock = await startMockServer()
  const sandbox = createSandbox('bot-clarify-card-width')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)

  const botHome = path.join(sandbox.hermesHome, 'profiles', 'alpha')
  fs.mkdirSync(botHome, { recursive: true })
  writeMockProviderConfig(botHome, mock.url)
  writeEnvFile(botHome)

  const builder = await RealSessionBuilder.start(botHome)

  try {
    await builder.createSession({ title: 'Bot Chat', turns: ['hello'] })
  } finally {
    await builder.close()
  }

  const { app, page } = await launchDesktop(buildAppEnv(sandbox))

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
  await resizeWindow(1440)
  await waitForAppReady(fixture, 120_000)
})

test.afterAll(async () => {
  await fixture?.cleanup()
  fixture = null
})

test('a multi-question clarify card takes the readable bubble width in Bot Chat instead of collapsing', async () => {
  test.setTimeout(240_000)
  const page = fixture!.page
  await page.emulateMedia({ colorScheme: 'light' })

  const row = page.locator('[data-slot="bots-roster"] [data-roster-key="local::alpha"]')

  if (!(await row.isVisible())) {
    await page
      .getByRole('button', { name: 'Bots', exact: true })
      .or(page.getByRole('tab', { name: 'Bots', exact: true }))
      .first()
      .click()
  }

  await row.click()

  const botSurface = page.locator('[data-chat-surface][data-bot-chat]').filter({ visible: true }).first()
  await expect(botSurface).toBeVisible({ timeout: 60_000 })

  const composer = botSurface.locator('[contenteditable="true"]').first()
  await composer.click()
  await composer.type(WIDE_CLARIFY_TRIGGER, { delay: 20 })
  await page.keyboard.press('Enter')

  const card = botSurface.locator('form[data-clarify-batch]')
  await expect(card).toHaveCount(1, { timeout: 60_000 })
  await expect(card.getByText(WIDE_CLARIFY_QUESTIONS[0]!.question)).toBeVisible()

  const measure = async () =>
    card.evaluate(el => ({
      bubble: el.closest('[data-bubble="assistant"]')!.getBoundingClientRect().width,
      card: el.getBoundingClientRect().width,
      row: el.closest('[data-slot="bot-reply-row"]')!.getBoundingClientRect().width,
      overflows: document.documentElement.scrollWidth > window.innerWidth,
      viewport: window.innerWidth
    }))

  for (const width of [1440, 1000]) {
    await resizeWindow(width)
    await expect.poll(async () => (await measure()).viewport).toBeGreaterThanOrEqual(width - 16)
    await page.mouse.move(0, 0)
    await capture(page, `width-${width}`)

    const sizes = await measure()
    const available = Math.min(READABLE_MAX_PX, sizes.row - AVATAR_GUTTER_PX)
    expect.soft(sizes.bubble, `bubble fills the room it has at ${width}px`).toBeGreaterThanOrEqual(available - 1)
    expect.soft(sizes.card, `card fills its bubble at ${width}px`).toBeGreaterThanOrEqual(available - 40)
    expect.soft(sizes.bubble, `bubble at ${width}px`).toBeLessThanOrEqual(READABLE_MAX_PX)
    expect.soft(sizes.overflows).toBe(false)
  }

  await resizeWindow(600)
  await expect.poll(async () => (await measure()).viewport).toBeLessThanOrEqual(616)
  await capture(page, 'width-600')

  const narrow = await measure()
  expect(narrow.card).toBeLessThanOrEqual(narrow.row)
  expect(narrow.overflows).toBe(false)
})
