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

async function capture(
  page: Page,
  name: string,
  clip?: { height: number; width: number; x: number; y: number }
): Promise<void> {
  fs.mkdirSync(ARTIFACT_DIR, { recursive: true })
  await page.screenshot({ clip, path: path.join(ARTIFACT_DIR, `${name}.png`) })
}

const PENDING_PROBE = 'E2E_PENDING_PROBE'

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
  const mock = await startMockServer({ holdBeforeFirstTokenForPrompt: PENDING_PROBE })
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
    {
      width: Number(process.env.GROK_LAYOUT_WIDTH) || Math.max(VISUAL_WINDOW_WIDTH, 1400),
      height: Number(process.env.GROK_LAYOUT_HEIGHT) || VISUAL_WINDOW_HEIGHT
    }
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

  await expect
    .poll(async () => (await row.innerText()).split('\n').filter(Boolean).length, {
      message: 'roster row carries a second preview line',
      timeout: 30_000
    })
    .toBeGreaterThanOrEqual(2)
  await expect(row, 'preview quotes the last message').toContainText(/Hello/)

  const selectedRowBox = (await row.boundingBox())!

  expect(selectedRowBox.height, 'roster row is at least 52px tall').toBeGreaterThanOrEqual(52)
  expect(
    parseFloat(await row.evaluate(el => getComputedStyle(el).borderTopLeftRadius)),
    'selected roster row is a rounded rectangle'
  ).toBeGreaterThanOrEqual(12)
  expect(
    await row.evaluate(el => getComputedStyle(el).backgroundColor),
    'selected roster row has a fill'
  ).not.toBe('rgba(0, 0, 0, 0)')

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
  await page
    .getByText('alpha pinned to top')
    .locator('xpath=ancestor::*[.//button][1]')
    .getByRole('button')
    .first()
    .click({ timeout: 3_000 })
    .catch(() => undefined)
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

  const footerDisc = page.locator('[data-slot="account-initials"]').filter({ visible: true })
  const appsButton = page.locator('[data-slot="account-apps"]').filter({ visible: true })

  await expect(footerDisc, 'footer shows the initials disc').toBeVisible()
  expect((await footerDisc.boundingBox())?.width, 'initials disc is 40px').toBe(40)
  expect((await appsButton.boundingBox())?.width, 'apps button is a 40px circle').toBe(40)
  await capture(page, 'roster-grok-dark')
  await appsButton.click()
  await expect(page.getByRole('dialog'), 'apps button opens Connect apps').toBeVisible({ timeout: 10_000 })
  await page.keyboard.press('Escape')
  await expect(page.getByRole('dialog')).toHaveCount(0)

  const appFont = await page.evaluate(async () => {
    await document.fonts.ready
    await document.fonts.load('14px "Geist Variable"', 'chó hóng hớt')

    return {
      family: getComputedStyle(document.body).fontFamily,
      loaded: document.fonts.check('14px "Geist Variable"', 'chó hóng hớt')
    }
  })

  expect(appFont.family, 'app text uses Geist first').toMatch(/^"?Geist Variable"?,/)
  expect(appFont.loaded, 'Geist with Vietnamese glyphs is loaded').toBe(true)

  const betaRow = page.locator('[data-slot="bots-roster"] [data-roster-key="local::beta"]').first()
  const betaFace = betaRow.locator('svg[data-bot-face]').first()

  const leftEye = () =>
    betaFace.evaluate(svg => {
      const eye = svg.querySelector('[data-hb-eye="l"]') as SVGGElement | null

      if (!eye) {
        return { angle: Number.NaN, centreX: Number.NaN, transform: '' }
      }

      const matrix = eye.getScreenCTM()!
      const box = eye.getBoundingClientRect()

      return {
        angle: (Math.atan2(matrix.b, matrix.a) * 180) / Math.PI,
        centreX: box.x + box.width / 2,
        transform: eye.getAttribute('transform') ?? ''
      }
    })

  expect((await betaFace.boundingBox())?.width ?? 0, 'roster face is 48px').toBeGreaterThanOrEqual(46)
  await expect
    .poll(
      () =>
        betaFace.evaluate(svg =>
          Array.from(svg.querySelectorAll('[data-hb-lids]')).some(lids => lids.getAnimations().length > 0)
        ),
      { message: 'eyelids of an on-screen face run a CSS blink animation' }
    )
    .toBe(true)

  const resting = await leftEye()
  const faceWidth = (await betaFace.boundingBox())?.width ?? 0
  const rowBox = await betaRow.boundingBox()

  if (!rowBox) {
    throw new Error('beta roster row has no box')
  }

  await page.mouse.move(rowBox.x + rowBox.width / 2, rowBox.y + rowBox.height / 2)
  await page.mouse.move(rowBox.x + 4, rowBox.y + rowBox.height / 2, { steps: 6 })
  await expect
    .poll(async () => resting.centreX - (await leftEye()).centreX, {
      message: 'left eye travels left toward the pointer',
      timeout: 1_000
    })
    .toBeGreaterThanOrEqual(faceWidth * 0.1)
  await expect
    .poll(async () => Math.abs((await leftEye()).angle), { message: 'eyes stand upright on screen', timeout: 1_000 })
    .toBeLessThanOrEqual(3)
  await capture(page, 'roster-gaze-dark')

  const settledSamples = await betaFace.evaluate(
    svg =>
      new Promise<number[]>(resolve => {
        const samples: number[] = []

        const sample = () => {
          samples.push(svg.querySelector('[data-hb-eye="l"]')!.getBoundingClientRect().x)

          if (samples.length === 3) {
            resolve(samples)
          } else {
            requestAnimationFrame(sample)
          }
        }

        requestAnimationFrame(() => requestAnimationFrame(sample))
      })
  )

  expect(Math.max(...settledSamples) - Math.min(...settledSamples), 'eyes hold still for a still pointer').toBeLessThan(0.3)

  await page.mouse.move(rowBox.x + rowBox.width + 400, rowBox.y + rowBox.height / 2, { steps: 6 })
  await expect
    .poll(async () => (await leftEye()).transform, { message: 'eyes return to the baked idle pose', timeout: 1_000 })
    .toBe(resting.transform)

  const avatarTrigger = profile.getByRole('button', { name: 'Change avatar' })
  const profileFace = profile.locator('svg[data-bot-face]').first()

  const faceFills = () =>
    profileFace.evaluate(svg =>
      Array.from(svg.querySelectorAll('[fill]'))
        .map(node => node.getAttribute('fill'))
        .filter(fill => fill && fill !== 'none')
        .join('|')
    )

  const avatarBox = (await avatarTrigger.boundingBox())!
  const fillsBefore = await faceFills()

  await avatarTrigger.click()

  const avatarCard = page.locator('[data-slot="bot-avatar-popover"]')

  await expect(avatarCard, 'avatar card opens').toBeVisible({ timeout: 10_000 })

  const cardBox = (await avatarCard.boundingBox())!

  expect(cardBox.y, 'card sits under the avatar').toBeGreaterThanOrEqual(avatarBox.y + avatarBox.height - 8)

  for (const name of ['Bot', 'Generate', 'Upload']) {
    await expect(avatarCard.getByRole('tab', { name, exact: true }), `${name} tab`).toBeVisible()
  }

  await expect(avatarCard.getByRole('button', { name: 'Reset', exact: true })).toBeVisible()

  const shapeOptions = avatarCard.getByRole('radiogroup').first().getByRole('radio')
  const swatchOptions = avatarCard.getByRole('radiogroup').nth(1).getByRole('radio')

  expect(await shapeOptions.count(), 'card offers at least ten shapes').toBeGreaterThanOrEqual(10)
  await swatchOptions.nth(4).click()
  await expect
    .poll(faceFills, { message: 'header face takes the picked colour', timeout: 10_000 })
    .not.toBe(fillsBefore)
  await capture(page, 'avatar-popover-dark')
  await page.keyboard.press('Escape')
  await expect(avatarCard, 'Escape closes the avatar card').toHaveCount(0)

  const paneTab = (name: string) => page.getByRole('tab', { name }).filter({ visible: true }).first()

  await expect(paneTab('Details')).toBeVisible()
  await expect(paneTab('Computer')).toBeVisible()
  await expect(page.locator('[data-slot="bot-details-summary"]').filter({ visible: true })).toBeVisible({
    timeout: 15_000
  })
  await capture(page, 'u10-details-dark')

  await paneTab('Run history').click()
  await expect(page.getByText('No runs yet').filter({ visible: true })).toBeVisible({ timeout: 15_000 })
  await capture(page, 'u10-run-history-dark')
  await paneTab('Details').click()

  await page.getByRole('button', { name: 'Search bots and group chats' }).filter({ visible: true }).first().click()

  const searchBox = page.getByRole('textbox', { name: 'Search', exact: true })

  await searchBox.fill('alpha')
  await expect(page.getByRole('option').filter({ visible: true }).first()).toBeVisible({ timeout: 15_000 })
  await capture(page, 'u10-search-dark')
  await page.keyboard.press('Escape')
  await expect(searchBox).toHaveCount(0)

  await page.locator('[data-tour="model-pill"]').filter({ visible: true }).first().click()

  const modelMenu = page.locator('[role="menu"]').filter({ visible: true }).first()

  await expect(modelMenu).toBeVisible({ timeout: 10_000 })

  const menuLook = await modelMenu.evaluate(node => {
    const style = getComputedStyle(node)
    const values = (style.backgroundColor.match(/-?\d*\.?\d+/g) ?? []).slice(0, 3).map(Number)
    const scaled = style.backgroundColor.startsWith('color(') ? values.map(value => value * 255) : values

    return { brightest: Math.max(...scaled), radius: parseFloat(style.borderTopLeftRadius) }
  })

  expect(menuLook.brightest, 'model menu is near-black in dark mode').toBeLessThan(24)
  expect(menuLook.radius, 'model menu has rounded corners').toBeGreaterThanOrEqual(8)
  await capture(page, 'model-menu-dark')
  await page.keyboard.press('Escape')

  const editor = page.locator('[data-chat-surface][data-bot-chat] [contenteditable="true"]').filter({ visible: true }).first()

  await editor.click()
  await editor.fill(PENDING_PROBE)
  await page.keyboard.press('Enter')
  await fixture!.mock.waitForHeldStream()

  const pendingRow = page.locator('[data-bot-chat] [data-bot-pending]').filter({ visible: true }).first()

  await expect(pendingRow).toHaveText('Reviewing your request', { timeout: 15_000 })
  await expect(pendingRow.locator('.dither'), 'no pulse square while a bot is pending').toHaveCount(0)

  const pendingBubble = await pendingRow.evaluate(node => {
    const bubble = node.closest('[data-bubble="assistant"]')!
    const style = getComputedStyle(bubble)
    const row = node.closest('[data-slot="bot-reply-row"]')!
    const avatar = row.querySelector('[data-slot="bot-reply-avatar"]')!.getBoundingClientRect()
    const text = node.getBoundingClientRect()

    return {
      background: style.backgroundColor,
      borderColor: style.borderTopColor,
      centreGap: Math.abs(avatar.top + avatar.height / 2 - (text.top + text.height / 2))
    }
  })

  expect(pendingBubble.background, 'pending bot reply has no card fill').toBe('rgba(0, 0, 0, 0)')
  expect(pendingBubble.borderColor, 'pending bot reply has no card border').toBe('rgba(0, 0, 0, 0)')
  expect(pendingBubble.centreGap, 'avatar and status text share a centre line').toBeLessThanOrEqual(2)
  await capture(page, 'bot-pending-dark')
  fixture!.mock.releaseHeldStream()
  await expect(page.locator('[data-bot-chat] [data-bot-pending]').filter({ visible: true })).toHaveCount(0, {
    timeout: 30_000
  })

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
  const paneBox = (await page.locator('[data-bots-pane]').filter({ visible: true }).first().boundingBox())!
  expect(Math.abs(plusBox.y + plusBox.height / 2 - 26), '+ centre within tolerance').toBeLessThanOrEqual(1.5)
  expect(
    Math.abs(paneBox.x + paneBox.width - (plusBox.x + plusBox.width) - 16),
    '+ right inset is 16px'
  ).toBeLessThanOrEqual(2)

  if (process.platform === 'darwin') {
    const buttons = await fixture!.app.evaluate(({ BrowserWindow }) =>
      BrowserWindow.getAllWindows()[0]?.getWindowButtonPosition()
    )

    expect(buttons, 'traffic lights relaxed in Bot Mode').toEqual({ x: 20, y: 19 })
  }

  await expect(page.locator('[data-slot="bots-roster"]').filter({ visible: true })).toBeVisible()
  await expect(sessionsNav, 'sessions surfaces are gone').toHaveCount(0)
  await capture(page, `${process.env.GROK_LAYOUT_SHOT_NAME ?? 'after'}-bots-only`)
  await capture(page, 'bots-only-toolbar', { x: paneBox.x, y: 0, width: paneBox.width, height: 80 })

  await newMenu.click()
  await page.getByRole('menuitem', { name: 'Show sessions' }).click()
  await page.locator('[data-slot="account-pill"]').filter({ visible: true }).click()
  await expect(
    page.locator('[data-slot="account-menu"]').getByRole('menuitem', { name: /^Sidebar panes/ }),
    'pane switching returns to the account menu with the sessions tab'
  ).toBeVisible({ timeout: 10_000 })
  await page.keyboard.press('Escape')
  await capture(page, `${process.env.GROK_LAYOUT_SHOT_NAME ?? 'after'}-sessions`)
})
