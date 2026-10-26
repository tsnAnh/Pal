import fs from 'node:fs'
import path from 'node:path'

import type { Locator, Page } from '@playwright/test'

import { writeEnvFile, writeMockProviderConfig } from '../../../tests-js/scripts/mock-provider-config'
import { startMockServer } from '../../../tests-js/scripts/mock-server'

import { buildAppEnv, createSandbox, launchDesktop, type MockBackendFixture, waitForAppReady } from './fixtures'
import { RealSessionBuilder } from './real-session-builder'
import { expect, test } from './test'
import { VISUAL_WINDOW_HEIGHT, VISUAL_WINDOW_WIDTH } from './visual-snapshot'

const ARTIFACT_DIR = process.env.BOT_CHROME_SCOPE_SCREENSHOT_DIR ?? '/tmp/bot-chrome-scope'

const REGULAR_TITLE = 'E2E Chrome Scope Chat'
const REGULAR_PROMPT = 'E2E_CHROME_SCOPE_PROMPT'
const BOT_GREETING = 'Hello alpha'
const TRAFFIC_LIGHTS = { height: 34, width: 82 }

let fixture: MockBackendFixture | null = null

async function capture(page: Page, name: string): Promise<void> {
  fs.mkdirSync(ARTIFACT_DIR, { recursive: true })
  await page.screenshot({ path: path.join(ARTIFACT_DIR, `${name}.png`) })
}

async function boxOf(locator: Locator) {
  const box = await locator.boundingBox()

  expect(box, 'element is laid out').not.toBeNull()

  return box!
}

const statusbar = (page: Page) => page.locator('[data-slot="statusbar"]')
const accountPill = (page: Page) => page.locator('[data-slot="account-pill"]').filter({ visible: true })
const accountMenu = (page: Page) => page.locator('[data-slot="account-menu"]')
const visibleHeaders = (page: Page) => page.locator('[data-tree-group] > [data-panel-header]').filter({ visible: true })
const botSurface = (page: Page) => page.locator('[data-chat-surface][data-bot-chat]').filter({ visible: true })
const regularSurface = (page: Page) => page.locator('[data-chat-surface]:not([data-bot-chat])').filter({ visible: true })

const settingsButton = (page: Page) =>
  page.getByRole('button', { name: 'Open settings', exact: true }).filter({ visible: true })

async function seedProfile(hermesHome: string, mockUrl: string, name: string, greeting: string): Promise<void> {
  const dir = path.join(hermesHome, 'profiles', name)
  fs.mkdirSync(dir, { recursive: true })
  writeMockProviderConfig(dir, mockUrl)
  writeEnvFile(dir)

  const builder = await RealSessionBuilder.start(dir)

  try {
    await builder.createSession({ title: 'Bot Chat', turns: [greeting] })
  } finally {
    await builder.close()
  }
}

async function openBotsPane(page: Page): Promise<void> {
  await page
    .getByRole('button', { name: 'Bots', exact: true })
    .or(page.getByRole('tab', { name: 'Bots', exact: true }))
    .first()
    .click()
}

async function openBotChat(page: Page): Promise<void> {
  await openBotsPane(page)

  const row = page.locator('[data-slot="bots-roster"] [data-roster-key="local::alpha"]').filter({ visible: true })
  await expect(row).toBeVisible({ timeout: 30_000 })
  await row.click()
  await expect(botSurface(page).first()).toContainText(BOT_GREETING, { timeout: 60_000 })
}

async function openRegularChat(page: Page): Promise<void> {
  const toDefault = page.getByRole('button', { name: 'Switch to default' })

  if (
    await toDefault.waitFor({ state: 'visible', timeout: 15_000 }).then(
      () => true,
      () => false
    )
  ) {
    await toDefault.click()
  }

  await page
    .getByRole('group', { name: 'Sidebar panes' })
    .getByRole('button', { name: 'Sessions', exact: true })
    .click()
  await page.locator('[data-slot="sidebar"] button').filter({ hasText: REGULAR_TITLE }).first().click()
  await expect(regularSurface(page).first()).toContainText(REGULAR_PROMPT, { timeout: 60_000 })
}

async function openAccountMenu(page: Page): Promise<void> {
  await accountPill(page).click()
  await expect(accountMenu(page)).toBeVisible()
}

async function showSessionsPane(page: Page): Promise<void> {
  await openAccountMenu(page)
  await accountMenu(page)
    .getByRole('menuitem', { name: /^Sidebar panes/ })
    .click()
  await page.getByRole('menuitemradio', { name: 'Sessions', exact: true }).click()
  await expect(page.locator('[data-slot="sidebar"]').filter({ visible: true }).first()).toBeVisible({ timeout: 15_000 })
}

async function leaveBotSurface(page: Page): Promise<void> {
  await showSessionsPane(page)
  await page.locator('[data-slot="sidebar"] button').filter({ hasText: REGULAR_TITLE }).first().click()
  await expect(regularSurface(page).first()).toContainText(REGULAR_PROMPT, { timeout: 60_000 })
  await expect(visibleHeaders(page).first(), 'titlebar row returns in a regular chat').toBeVisible({ timeout: 15_000 })
}

async function contentUnderTrafficLights(page: Page): Promise<string[]> {
  return page.evaluate(({ height, width }) => {
    const hits: string[] = []

    const inBand = (rect: DOMRect) =>
      rect.width > 0 && rect.height > 0 && rect.left < width && rect.top < height && rect.right > 0 && rect.bottom > 0

    const shown = (el: Element) => {
      const style = getComputedStyle(el)

      return style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity) > 0
    }

    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)

    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const text = node.textContent?.trim()
      const parent = node.parentElement

      if (!text || !parent || !shown(parent) || ['NOSCRIPT', 'SCRIPT', 'STYLE'].includes(parent.tagName)) {
        continue
      }

      const range = document.createRange()
      range.selectNodeContents(node)

      if ([...range.getClientRects()].some(inBand)) {
        hits.push(`text:${text.slice(0, 40)}`)
      }
    }

    const interactive = 'button, a[href], input, textarea, [contenteditable="true"], [role="tab"], [role="button"], img, svg'

    for (const el of document.querySelectorAll(interactive)) {
      if (shown(el) && inBand(el.getBoundingClientRect())) {
        hits.push(`${el.tagName.toLowerCase()}:${el.getAttribute('aria-label') ?? el.getAttribute('data-slot') ?? ''}`)
      }
    }

    return hits
  }, TRAFFIC_LIGHTS)
}

async function trafficLightsDragRegion(page: Page): Promise<boolean> {
  return page.evaluate(({ height, width }) => {
    const x = width / 2
    const y = height / 2

    return [...document.querySelectorAll('*')].some(el => {
      if (getComputedStyle(el).getPropertyValue('-webkit-app-region') !== 'drag') {
        return false
      }

      const rect = el.getBoundingClientRect()

      return rect.left <= x && rect.right >= x && rect.top <= y && rect.bottom >= y
    })
  }, TRAFFIC_LIGHTS)
}

async function expectClearOfTrafficLights(page: Page, label: string): Promise<void> {
  expect(await contentUnderTrafficLights(page), `${label}: nothing is drawn under the traffic lights`).toEqual([])
  expect(await trafficLightsDragRegion(page), `${label}: the traffic-light band drags the window`).toBe(true)
}

test.beforeAll(async () => {
  const mock = await startMockServer()
  const sandbox = createSandbox('bot-chrome-scope')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)

  const regular = await RealSessionBuilder.start(sandbox.hermesHome)

  try {
    await regular.createSession({ title: REGULAR_TITLE, turns: [REGULAR_PROMPT] })
  } finally {
    await regular.close()
  }

  await seedProfile(sandbox.hermesHome, mock.url, 'alpha', BOT_GREETING)

  fs.writeFileSync(
    path.join(sandbox.hermesHome, 'auth.json'),
    JSON.stringify({
      providers: { nous: { auth_method: 'anonymous', guest_notice_shown: true, welcome_claim: true } },
      version: 1
    })
  )

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

test('window chrome follows the visible chats, and the statusbar stays reachable on bot surfaces', async () => {
  test.setTimeout(600_000)
  const page = fixture!.page

  await openRegularChat(page)
  await expect(statusbar(page), 'regular chat shows the statusbar').toBeVisible({ timeout: 30_000 })
  await expect(settingsButton(page), 'regular chat shows the titlebar tools').toBeVisible()
  await capture(page, '01-regular-chat')

  await page.keyboard.press('ControlOrMeta+Shift+S')
  await expect(statusbar(page), 'the shortcut hides the bar on a regular chat').toHaveCount(0)

  await openBotChat(page)
  await expect(visibleHeaders(page), 'bot chat drops the titlebar row').toHaveCount(0)
  await expect(statusbar(page), 'bot chat has no statusbar').toHaveCount(0)
  await expect(accountPill(page)).toBeVisible({ timeout: 15_000 })
  await capture(page, '02-bot-chat')

  await page.keyboard.press('ControlOrMeta+Shift+S')
  await expect(statusbar(page), 'the shortcut on a bot surface shows the bar even though the preference is off').toBeVisible({
    timeout: 15_000
  })
  await expect(visibleHeaders(page), 'showing the bar does not bring the titlebar back').toHaveCount(0)
  await capture(page, '03-bot-chat-statusbar-forced-on')

  await page.keyboard.press('ControlOrMeta+Shift+S')
  await expect(statusbar(page), 'the shortcut again hides the forced bar').toHaveCount(0)

  await page.keyboard.press('ControlOrMeta+K')

  const paletteInput = page.locator('[cmdk-input]')
  await expect(paletteInput).toBeVisible()
  await paletteInput.fill('Toggle status bar')

  const paletteRow = page.locator('[cmdk-item]').filter({ hasText: 'Toggle status bar' }).first()
  await expect(paletteRow).toContainText('off')
  await paletteInput.press('ArrowDown')
  await expect(paletteRow).toHaveAttribute('aria-selected', 'true')
  await paletteInput.press('Enter')
  await expect(statusbar(page), 'the palette action shows the bar on a bot surface').toBeVisible({ timeout: 15_000 })
  await expect(paletteRow, 'the palette reports the bar as on').toContainText('on')
  await capture(page, '04-palette-statusbar-on')
  await page.keyboard.press('Escape')
  await expect(paletteInput).toHaveCount(0)

  await leaveBotSurface(page)
  await expect(statusbar(page), 'leaving the bot surface drops the override and restores the hidden preference').toHaveCount(
    0
  )
  await openBotChat(page)
  await expect(statusbar(page), 'coming back to a bot surface starts without the override').toHaveCount(0)

  await leaveBotSurface(page)
  await page.keyboard.press('ControlOrMeta+Shift+S')
  await expect(statusbar(page), 'the preference is restored for regular chats').toBeVisible({ timeout: 15_000 })

  await openBotChat(page)
  await expect(statusbar(page)).toHaveCount(0)

  await openAccountMenu(page)

  const gatewayRow = accountMenu(page).locator('[data-slot="account-gateway-health"]')
  await expect(gatewayRow, 'account menu carries the gateway health entry').toBeVisible()
  await expect(gatewayRow).toContainText('Connected')
  await expect(accountMenu(page).getByRole('menuitem', { name: /^Toggle status bar/ })).toBeVisible()
  await expect(
    accountMenu(page).getByRole('menuitem', { name: /^Nous · / }),
    'account menu carries the free-tier sign-in entry'
  ).toContainText('Sign in')
  await gatewayRow.click()

  const reconnect = page.getByRole('button', { name: 'Reconnect gateway', exact: true })
  await expect(reconnect, 'gateway panel offers reconnect').toBeVisible({ timeout: 15_000 })
  await expect(page.getByRole('button', { name: 'Open system panel', exact: true })).toBeVisible()
  await capture(page, '05-account-menu-gateway-panel')
  await reconnect.click()
  await expect(gatewayRow, 'the gateway comes back after a reconnect').toContainText('Connected', { timeout: 60_000 })
  await page.keyboard.press('Escape')
  await page.keyboard.press('Escape')
  await expect(accountMenu(page)).toHaveCount(0)

  await openAccountMenu(page)
  await accountMenu(page)
    .getByRole('menuitem', { name: /^Toggle status bar/ })
    .click()
  await expect(statusbar(page), 'the account menu row shows the bar on a bot surface').toBeVisible({ timeout: 15_000 })
  await page.keyboard.press('ControlOrMeta+Shift+S')
  await expect(statusbar(page)).toHaveCount(0)

  await capture(page, '06-default-layout')
  await expectClearOfTrafficLights(page, 'default layout')

  await openAccountMenu(page)
  await accountMenu(page)
    .getByRole('menuitem', { name: /^Swap sidebar sides/ })
    .click()
  await expect(visibleHeaders(page), 'flipped bot chat keeps the titlebar row gone').toHaveCount(0)
  await capture(page, '07-panes-flipped')
  await expectClearOfTrafficLights(page, 'panes flipped')

  await page.keyboard.press('ControlOrMeta+B')
  await expect(page.locator('[data-bots-pane]').filter({ visible: true }), 'sidebar folds away').toHaveCount(0)
  await capture(page, '08-panes-flipped-sidebar-folded')
  await expectClearOfTrafficLights(page, 'panes flipped, sidebar folded')

  await page.keyboard.press('ControlOrMeta+\\')
  await capture(page, '09-sidebar-folded')
  await expectClearOfTrafficLights(page, 'sidebar folded')

  await page.keyboard.press('ControlOrMeta+B')
  await expect(page.locator('[data-bots-pane]').filter({ visible: true }).first()).toBeVisible({ timeout: 15_000 })
  await expectClearOfTrafficLights(page, 'default layout restored')

  await showSessionsPane(page)
  await expect(visibleHeaders(page), 'sessions pane beside a lone bot chat keeps the bot chrome').toHaveCount(0)
  await expect(statusbar(page)).toHaveCount(0)

  const newSession = page
    .locator('[data-slot="sidebar"]')
    .filter({ visible: true })
    .getByRole('button', { name: /^New session/ })
    .first()

  await newSession.click({ button: 'right' })
  await page.getByRole('menuitem', { name: 'Open in split' }).click()
  await page.keyboard.press('Escape')
  await page.keyboard.press('Escape')

  await expect(regularSurface(page).first(), 'a regular chat opens beside the bot chat').toBeVisible({ timeout: 30_000 })
  await expect(botSurface(page).first(), 'the bot chat stays on screen').toBeVisible()
  await capture(page, '10-split-bot-and-regular')
  await expect(visibleHeaders(page).first(), 'a split with a regular chat keeps the titlebar row').toBeVisible({
    timeout: 15_000
  })
  await expect(settingsButton(page), 'a split with a regular chat keeps the titlebar tools').toBeVisible()
  await expect(statusbar(page), 'a split with a regular chat keeps the statusbar').toBeVisible({ timeout: 15_000 })
  await expect(accountPill(page), 'the account dock leaves with the bot chrome').toHaveCount(0)
})
