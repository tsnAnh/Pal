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
  process.env.BOT_ACCOUNT_PILL_SCREENSHOT_DIR ?? path.join(process.cwd(), 'test-results', 'bot-account-pill')

const REGULAR_TITLE = 'E2E Regular Account Chat'
const REGULAR_PROMPT = 'E2E_REGULAR_ACCOUNT_PROMPT'
const BOT_GREETING = 'Hello alpha'
const TOP_TOLERANCE_PX = 4
const TRAFFIC_LIGHT_INSET_PX = 16

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

const visibleHeaders = (page: Page) => page.locator('[data-tree-group] > [data-panel-header]').filter({ visible: true })
const accountPill = (page: Page) => page.locator('[data-slot="account-pill"]').filter({ visible: true })
const accountMenu = (page: Page) => page.locator('[data-slot="account-menu"]')

async function openBotsPane(page: Page): Promise<void> {
  await page
    .getByRole('button', { name: 'Bots', exact: true })
    .or(page.getByRole('tab', { name: 'Bots', exact: true }))
    .first()
    .click()
}

async function openBotChat(page: Page): Promise<void> {
  const row = page.locator('[data-slot="bots-roster"] [data-roster-key="local::alpha"]').filter({ visible: true })
  await expect(row).toBeVisible({ timeout: 30_000 })
  await row.click()
  await expect(page.locator('[data-chat-surface][data-bot-chat]').filter({ visible: true }).first()).toContainText(
    BOT_GREETING,
    { timeout: 60_000 }
  )
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
  await expect(
    page.locator('[data-chat-surface]:not([data-bot-chat])').filter({ visible: true }).first()
  ).toContainText(REGULAR_PROMPT, { timeout: 60_000 })
}

async function expectNoTitlebarRow(page: Page, label: string): Promise<void> {
  await expect(visibleHeaders(page), `${label}: no titlebar row`).toHaveCount(0)
  await expect(
    page.getByRole('button', { name: 'Open settings', exact: true }).filter({ visible: true }),
    `${label}: titlebar tools are gone`
  ).toHaveCount(0)
}

async function expectContentAtTop(page: Page, selector: string, label: string): Promise<void> {
  const box = await boxOf(page.locator(selector).filter({ visible: true }).first())

  expect(box.y, `${label} starts at the window top`).toBeLessThanOrEqual(TOP_TOLERANCE_PX)
}

async function expectPillBottomLeft(page: Page, label: string): Promise<void> {
  const pill = accountPill(page)
  await expect(pill, `${label}: account pill is shown`).toBeVisible({ timeout: 15_000 })

  const box = await boxOf(pill)
  const viewport = page.viewportSize() ?? (await page.evaluate(() => ({ height: innerHeight, width: innerWidth })))
  const radius = await pill.evaluate(el => parseFloat(getComputedStyle(el).borderTopLeftRadius))

  expect(box.x, `${label}: pill hugs the left edge`).toBeLessThanOrEqual(40)
  expect(viewport.height - (box.y + box.height), `${label}: pill sits at the bottom`).toBeLessThanOrEqual(28)
  expect(box.height, `${label}: pill is 32px tall`).toBeGreaterThanOrEqual(31)
  expect(box.height, `${label}: pill is 32px tall`).toBeLessThanOrEqual(33)
  expect(radius, `${label}: pill is fully rounded`).toBeGreaterThanOrEqual(box.height / 2)

  const tools = page.locator('[data-slot="account-quick-tools"]').filter({ visible: true })
  const toolsBox = await boxOf(tools)

  expect(toolsBox.x, `${label}: quick-tools pill sits right of the name pill`).toBeGreaterThanOrEqual(box.x + box.width)
  expect(toolsBox.height, `${label}: quick-tools pill matches the pill height`).toBeCloseTo(box.height, 0)
  expect(toolsBox.width, `${label}: quick-tools pill is the smaller one`).toBeLessThan(box.width)
}

test.beforeAll(async () => {
  const mock = await startMockServer()
  const sandbox = createSandbox('bot-account-pill')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)

  const regular = await RealSessionBuilder.start(sandbox.hermesHome)

  try {
    await regular.createSession({ title: REGULAR_TITLE, turns: [REGULAR_PROMPT] })
  } finally {
    await regular.close()
  }

  for (const name of ['alpha', 'beta']) {
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

test('bot surfaces drop the titlebar row and move the app tools into the account pill', async () => {
  test.setTimeout(420_000)
  const page = fixture!.page

  await openRegularChat(page)

  const headerBox = await boxOf(visibleHeaders(page).first())

  expect(headerBox.height, 'regular chat keeps the 34px titlebar row').toBeGreaterThanOrEqual(34)
  await expect(
    page.getByRole('button', { name: 'Open settings', exact: true }).filter({ visible: true }),
    'regular chat keeps the titlebar tools'
  ).toBeVisible()
  await expect(accountPill(page), 'regular chat has no account pill').toHaveCount(0)
  await capture(page, '01-regular-chat-titlebar')

  await openBotsPane(page)
  await openBotChat(page)

  await expectNoTitlebarRow(page, 'bot chat')
  await expectContentAtTop(page, '[data-bots-pane]', 'roster pane')
  await expectContentAtTop(page, '[data-chat-surface][data-bot-chat]', 'bot chat')
  await expect(page.locator('[data-slot="bots-roster-toolbar"]').filter({ visible: true })).toBeVisible()

  const toolbarBox = await boxOf(page.locator('[data-slot="bots-roster-toolbar"]').filter({ visible: true }))

  const dragRegion = await page
    .locator('[data-slot="bots-roster-toolbar"]')
    .filter({ visible: true })
    .evaluate(el => getComputedStyle(el).getPropertyValue('-webkit-app-region'))

  expect(toolbarBox.y, 'roster toolbar row owns the traffic-light inset').toBeLessThanOrEqual(TOP_TOLERANCE_PX)
  expect(toolbarBox.height, 'toolbar row clears the traffic lights').toBeGreaterThanOrEqual(TRAFFIC_LIGHT_INSET_PX * 2)
  expect(dragRegion, 'roster top row drags the window').toBe('drag')

  await expectPillBottomLeft(page, 'bot chat')
  await capture(page, '02-bot-chat-pill-closed')

  await accountPill(page).click()
  await expect(accountMenu(page)).toBeVisible()

  const menuBox = await boxOf(accountMenu(page))
  const pillBox = await boxOf(accountPill(page))

  expect(menuBox.y + menuBox.height, 'menu opens above the pill').toBeLessThanOrEqual(pillBox.y)

  const menuStyle = await accountMenu(page).evaluate(el => ({
    radius: parseFloat(getComputedStyle(el).borderTopLeftRadius),
    rowFont: parseFloat(getComputedStyle(el.querySelector('[role="menuitem"]')!).fontSize),
    rowIcon: parseFloat(getComputedStyle(el.querySelector('[role="menuitem"] .codicon')!).fontSize)
  }))

  expect(menuStyle.radius, 'menu corners are ~16px').toBeGreaterThanOrEqual(16)
  expect(menuStyle.rowFont, 'menu rows are 15px').toBe(15)
  expect(menuStyle.rowIcon, 'menu row icons are 20px').toBe(20)

  const settingsRow = accountMenu(page).getByRole('menuitem', { name: /^Settings/ })
  await expect(settingsRow).toBeVisible()
  await expect(accountMenu(page).getByRole('menuitem', { name: /^Billing/ })).toBeVisible()
  await expect(accountMenu(page).getByRole('menuitem', { name: /^Profiles/ })).toBeVisible()
  await expect(accountMenu(page).getByRole('menuitem', { name: /^Layout editor/ })).toBeVisible()
  await expect(accountMenu(page).getByRole('menuitem', { name: /^Hide sidebar/ })).toBeVisible()
  await expect(accountMenu(page).getByRole('menuitem', { name: /^Sidebar panes/ })).toBeVisible()
  await expect(accountMenu(page).getByRole('menuitem', { name: /^Nous Portal Support/ })).toBeVisible()
  await expect(accountMenu(page).getByRole('menuitem', { name: /^Send diagnostics/ })).toBeVisible()
  await capture(page, '03-bot-chat-pill-menu-open')

  await accountMenu(page)
    .getByRole('menuitem', { name: /^Profiles/ })
    .click()
  await expect(page.getByRole('menuitemradio', { name: 'default', exact: true })).toBeVisible()
  await expect(page.getByRole('menuitemradio', { name: 'alpha', exact: true })).toBeVisible()
  await expect(page.getByRole('menuitem', { name: 'New profile', exact: true })).toBeVisible()
  await expect(page.getByRole('menuitem', { name: /^Manage profiles/ })).toBeVisible()
  await capture(page, '03b-bot-chat-profiles-submenu')

  await page.getByRole('menuitem', { name: 'New profile', exact: true }).click()
  await expect(page.getByRole('dialog')).toBeVisible({ timeout: 10_000 })
  await page.keyboard.press('Escape')
  await expect(page.getByRole('dialog')).toHaveCount(0)

  await accountPill(page).click()
  await expect(accountMenu(page)).toBeVisible()
  await settingsRow.click()
  await expect(page.getByRole('button', { name: 'Close settings', exact: true })).toBeVisible({ timeout: 15_000 })
  await capture(page, '04-settings-from-pill')
  await page.getByRole('button', { name: 'Close settings', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Close settings', exact: true })).toHaveCount(0)
  await expectNoTitlebarRow(page, 'bot chat after closing settings')

  await accountPill(page).click()
  await accountMenu(page)
    .getByRole('menuitem', { name: /^Sidebar panes/ })
    .click()
  await page.getByRole('menuitemradio', { name: 'Sessions', exact: true }).click()
  await expect(page.locator('[data-slot="sidebar"]').filter({ visible: true }).first()).toBeVisible({ timeout: 15_000 })
  await expectNoTitlebarRow(page, 'sessions pane in a bot chat')
  await expectPillBottomLeft(page, 'sessions pane in a bot chat')
  await capture(page, '05-sessions-pane-in-bot-chat')

  await page.locator('[data-slot="sidebar"] button').filter({ hasText: REGULAR_TITLE }).first().click()
  await expect(
    page.locator('[data-chat-surface]:not([data-bot-chat])').filter({ visible: true }).first()
  ).toContainText(REGULAR_PROMPT, { timeout: 60_000 })
  await expect(visibleHeaders(page).first(), 'titlebar row returns in a regular chat').toBeVisible({ timeout: 15_000 })
  await expect(accountPill(page), 'account pill leaves with the bot surface').toHaveCount(0)
  await capture(page, '06-regular-chat-again')

  await openBotsPane(page)

  const newMenu = page.getByRole('button', { name: 'New bot or group chat' }).filter({ visible: true }).first()
  await newMenu.click()
  await page.getByRole('menuitem', { name: 'Bots-only mode' }).click()

  await expect(page.getByRole('group', { name: 'Sidebar panes' })).toHaveCount(0)
  await expectNoTitlebarRow(page, 'bots-only mode')
  await expectContentAtTop(page, '[data-bots-pane]', 'roster pane in bots-only mode')
  await expectPillBottomLeft(page, 'bots-only mode')

  const plusBox = await boxOf(
    page.getByRole('button', { name: 'New bot or group chat' }).filter({ visible: true }).first()
  )

  expect(plusBox.y + plusBox.height / 2, '+ sits in the roster top row').toBeLessThanOrEqual(34)
  await capture(page, '07-bots-only-pill-closed')

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
                animation =>
                  animation.playState === 'running' &&
                  String((animation as CSSTransition).transitionProperty).includes('color')
              ).length
        ),
      { message: 'theme color transitions settle before the dark capture', timeout: 10_000 }
    )
    .toBe(0)
  await capture(page, '07b-bots-only-pill-closed-dark')

  await accountPill(page).click()
  await expect(accountMenu(page)).toBeVisible()
  await expect(
    accountMenu(page).getByRole('menuitem', { name: /^(Hide|Show) sidebar/ }),
    'bots-only mode has no sidebar toggle'
  ).toHaveCount(0)
  await capture(page, '08-bots-only-pill-menu-open-dark')
  await page.keyboard.press('Escape')

  await page.getByRole('button', { name: 'New bot or group chat' }).filter({ visible: true }).first().click()
  await page.getByRole('menuitem', { name: 'Show sessions' }).click()
  await expect(page.getByRole('group', { name: 'Sidebar panes' })).toBeVisible({ timeout: 10_000 })
})
