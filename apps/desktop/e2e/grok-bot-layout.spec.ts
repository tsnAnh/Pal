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
  process.env.GROK_LAYOUT_SCREENSHOT_DIR ?? path.join(process.cwd(), 'test-results', 'grok-bot-layout')

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
  const sandbox = createSandbox('grok-bot-layout')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)

  for (const name of ['alpha', 'beta', 'gamma']) {
    await seedBot(sandbox.hermesHome, mock.url, name)
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

test('bot roster, chat bubbles and profile panel follow the Grok Bot layout', async () => {
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
  await page
    .getByText(/Waking up/i)
    .first()
    .waitFor({ state: 'hidden', timeout: 90_000 })
    .catch(() => undefined)

  await row.click({ button: 'right' })
  await page.getByRole('menuitem', { name: 'Pin to top' }).click()

  const strip = page.locator('[data-slot="bots-pinned-strip"]')
  await expect(strip.locator('[data-roster-key="local::alpha"]')).toBeVisible({ timeout: 15_000 })
  await expect(
    page.locator('[data-roster-key="local::alpha"]').filter({ visible: true }),
    'pinned bot leaves the list'
  ).toHaveCount(1)

  const userBubble = page.locator('[data-bubble="user"]').filter({ visible: true }).first()
  const assistantCard = page.locator('[data-bubble="assistant"]').filter({ visible: true }).first()
  await expect(userBubble).toBeVisible()
  await expect(assistantCard).toBeVisible()

  const userBox = (await userBubble.boundingBox())!
  const assistantBox = (await assistantCard.boundingBox())!
  expect(userBox.x, 'user bubble sits right of the assistant card').toBeGreaterThan(assistantBox.x + 100)
  expect(
    parseFloat(await userBubble.evaluate(el => getComputedStyle(el).borderTopLeftRadius)),
    'user bubble is a pill'
  ).toBeGreaterThanOrEqual(16)
  expect(
    await assistantCard.evaluate(el => getComputedStyle(el).backgroundColor),
    'assistant card has a fill'
  ).not.toBe('rgba(0, 0, 0, 0)')

  const channels = (color: string) => {
    const values = color
      .match(/-?\d*\.?\d+/g)!
      .slice(0, 3)
      .map(Number)

    return color.startsWith('color(') ? values.map(value => value * 255) : values
  }

  expect(
    await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--dt-bot-accent').trim()),
    'bot accent does not leak onto the document root'
  ).toBe('')

  const [red, green, blue] = channels(await userBubble.evaluate(el => getComputedStyle(el).backgroundColor))
  expect(
    Math.max(red!, green!, blue!) - Math.min(red!, green!, blue!),
    'user bubble is neutral grey'
  ).toBeLessThanOrEqual(2)

  const replyName = page.locator('[data-slot="bot-reply-name"]').filter({ visible: true }).first()
  await expect(replyName, 'reply carries the bot name above the card').toHaveText('alpha')
  const nameBox = (await replyName.boundingBox())!
  expect(nameBox.y + nameBox.height, 'name sits above the card').toBeLessThanOrEqual(assistantBox.y)

  const replyFace = page.locator('[data-slot="bot-reply-avatar"]').filter({ visible: true }).first()
  const faceBox = (await replyFace.boundingBox())!
  expect(faceBox.width, 'reply face is 20px').toBe(20)
  expect(faceBox.x + faceBox.width + 14, 'card starts 14px right of the face').toBeCloseTo(assistantBox.x, 0)

  expect(await assistantCard.evaluate(el => getComputedStyle(el).maxWidth), 'reply card caps at Grok width').toBe(
    '552px'
  )

  const composer = page
    .locator('[data-chat-surface][data-bot-chat] [data-slot="composer-root"]')
    .filter({ visible: true })
    .first()

  const composerBox = (await composer.boundingBox())!

  const surfaceBox = (await page
    .locator('[data-chat-surface][data-bot-chat]')
    .filter({ visible: true })
    .first()
    .boundingBox())!

  expect(composerBox.width, 'composer column is at most 960px').toBeLessThanOrEqual(960 + 12)
  expect(
    Math.abs(composerBox.x + composerBox.width / 2 - (surfaceBox.x + surfaceBox.width / 2)),
    'composer is centred in the chat surface'
  ).toBeLessThanOrEqual(2)
  expect(userBox.x + userBox.width, 'user bubble ends on the column edge').toBeGreaterThan(
    surfaceBox.x + surfaceBox.width / 2
  )

  const profile = page.locator('[data-slot="bot-profile-header"]').filter({ visible: true }).first()
  await expect(profile).toBeVisible({ timeout: 15_000 })
  await expect(profile).toContainText(/alpha/i)

  await expect(page.locator('[data-slot="bot-title-chip"]').filter({ visible: true })).toContainText(/alpha/i)
  await expect(
    page
      .locator('[placeholder="Message alpha"], [aria-placeholder="Message alpha"], [data-placeholder="Message alpha"]')
      .filter({ visible: true })
  ).toBeVisible()

  const botSurface = page.locator('[data-chat-surface][data-bot-chat]').filter({ visible: true }).first()

  await expect(
    botSurface.getByRole('button', { name: /^(Model · |Switch model$|Open model picker$)/ }),
    'bot composer offers model selection'
  ).toBeVisible()
  await expect(
    botSurface.getByRole('button', { name: 'Start voice conversation' }),
    'bot composer has no voice-conversation button'
  ).toHaveCount(0)
  await expect(
    botSurface.getByRole('button', { name: 'Voice dictation' }),
    'bot composer keeps dictation'
  ).toBeVisible()
  await expect(
    botSurface.getByRole('button', { name: /^(Tasks|Previous tasks) \d+\/\d+$/ }),
    'bot composer status stack carries no todo group'
  ).toHaveCount(0)

  await expect(
    page.getByText('Share usage stats?').filter({ visible: true }),
    'bot chats never carry the usage-stats strip'
  ).toHaveCount(0)
  await capture(page, process.env.GROK_LAYOUT_SHOT_NAME ?? 'after')

  await page.emulateMedia({ colorScheme: 'dark' })
  await expect(page.locator('html')).toHaveClass(/dark/, { timeout: 10_000 })
  await expect
    .poll(
      () =>
        page.evaluate(
          () =>
            document
              .getAnimations()
              .filter(
                a => a.playState === 'running' && String((a as CSSTransition).transitionProperty).includes('color')
              ).length
        ),
      { message: 'theme color transitions settle before the dark capture', timeout: 10_000 }
    )
    .toBe(0)
  expect(
    await page
      .locator('[data-slot="bots-roster"]')
      .first()
      .evaluate(el => {
        let node: Element | null = el

        while (node && getComputedStyle(node).backgroundColor === 'rgba(0, 0, 0, 0)') {
          node = node.parentElement
        }

        const color = node ? getComputedStyle(node).backgroundColor : ''
        const values = (color.match(/-?\d*\.?\d+/g) ?? []).slice(0, 3).map(Number)

        return Math.max(...(color.startsWith('color(') ? values.map(value => value * 255) : values))
      }),
    'bots sidebar is near-black in dark mode'
  ).toBeLessThan(40)
  await capture(page, `${process.env.GROK_LAYOUT_SHOT_NAME ?? 'after'}-dark`)

  await expect(
    page.getByText(/^profile$/i).filter({ visible: true }),
    'no tab strip label over the profile panel'
  ).toHaveCount(0)
  await expect(
    page
      .getByText(/^alpha$/i)
      .filter({ visible: true })
      .and(page.locator('[role="tab"]')),
    'no workspace tab for the chat'
  ).toHaveCount(0)

  await profile.getByRole('button', { name: 'Close' }).click()
  await expect(page.locator('[data-slot="bot-profile-header"]').filter({ visible: true })).toHaveCount(0, {
    timeout: 10_000
  })
  await capture(page, `${process.env.GROK_LAYOUT_SHOT_NAME ?? 'after'}-panel-closed`)

  const newMenu = page.getByRole('button', { name: 'New bot or group chat' }).filter({ visible: true }).first()
  const sessionsNav = page.getByText('Scheduled jobs', { exact: true }).filter({ visible: true })
  const switcher = page.getByRole('group', { name: 'Sidebar panes' })

  await newMenu.click()
  await page.getByRole('menuitem', { name: 'Bots-only mode' }).click()
  await expect(switcher, 'pane switcher leaves with the sessions tab').toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Hide sidebar' }), 'sidebar toggle leaves too').toHaveCount(0)
  await expect(
    page.locator('[data-tree-group] > [data-panel-header]').filter({ visible: true }),
    'bots-only mode has no titlebar row'
  ).toHaveCount(0)
  const plusBox = (await newMenu.boundingBox())!
  expect(plusBox.y + plusBox.height / 2, '+ sits in the roster top row').toBeLessThanOrEqual(34)
  await expect(page.locator('[data-slot="bots-roster"]').filter({ visible: true })).toBeVisible()
  await expect(sessionsNav, 'sessions surfaces are gone').toHaveCount(0)
  await capture(page, `${process.env.GROK_LAYOUT_SHOT_NAME ?? 'after'}-bots-only`)

  await newMenu.click()
  await page.getByRole('menuitem', { name: 'Show sessions' }).click()
  await page.locator('[data-slot="account-pill"]').filter({ visible: true }).click()
  await expect(
    page.locator('[data-slot="account-menu"]').getByRole('menuitem', { name: /^Sidebar panes/ }),
    'pane switching returns to the account menu with the sessions tab'
  ).toBeVisible({ timeout: 10_000 })
  await page.keyboard.press('Escape')
})
