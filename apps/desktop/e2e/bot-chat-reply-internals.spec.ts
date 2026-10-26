import fs from 'node:fs'
import path from 'node:path'

import type { Locator, Page } from '@playwright/test'

import { writeEnvFile, writeMockProviderConfig } from '../../../tests-js/scripts/mock-provider-config'
import {
  APPROVAL_COMMAND_TRIGGER,
  MOCK_REPLY,
  SINGLE_BATCH_CLARIFY_QUESTIONS,
  SINGLE_BATCH_CLARIFY_TRIGGER,
  startMockServer
} from '../../../tests-js/scripts/mock-server'

import { buildAppEnv, createSandbox, launchDesktop, type MockBackendFixture, waitForAppReady } from './fixtures'
import { RealSessionBuilder } from './real-session-builder'
import { expect, test } from './test'
import { VISUAL_WINDOW_HEIGHT, VISUAL_WINDOW_WIDTH } from './visual-snapshot'

const ARTIFACT_DIR =
  process.env.BOT_REPLY_INTERNALS_SCREENSHOT_DIR ?? path.join(process.cwd(), 'test-results', 'bot-chat-reply-internals')

const THOUGHT = 'E2E_PRIVATE_THOUGHT_MARKER'
const COMMAND_MARKER = 'e2e-internal-command-marker'
const REPLY_MARKER = 'E2E_CALL_RESULT'
const REGULAR_TITLE = 'E2E Regular Internals Chat'
const PROMPT = `E2E_THINK[${THOUGHT}] E2E_CALL(terminal)[{"command":"echo ${COMMAND_MARKER}"}] E2E_CALL(terminal)[{"command":"echo ${COMMAND_MARKER}-again"}]`
const LIVE_PROMPT = `E2E_THINK[${THOUGHT}] E2E_CALL(terminal)[{"command":"echo ${COMMAND_MARKER}-live"}] E2E_CALL(terminal)[{"command":"echo ${COMMAND_MARKER}-live-again"}]`
const FAILED_PATH = '/e2e-missing-path-marker'
const FAILED_PROMPT = `E2E_CALL(terminal)[{"command":"ls ${FAILED_PATH}"}]`
const SEED_PROMPT = 'hello'
const LIVE_BOT = 'beta'
const FAILED_BOT = 'gamma'
const APPROVAL_BOT = 'delta'
const RELOADED_FAILED_BOT = 'epsilon'

let fixture: MockBackendFixture | null = null

async function capture(page: Page, name: string): Promise<void> {
  fs.mkdirSync(ARTIFACT_DIR, { recursive: true })
  await page.screenshot({ path: path.join(ARTIFACT_DIR, `${name}.png`) })
}

async function seedChat(home: string, title: string, prompt: string): Promise<void> {
  const builder = await RealSessionBuilder.start(home)

  try {
    await builder.createSession({ title, turns: [prompt] })
  } finally {
    await builder.close()
  }
}

async function visibleCardsAreNonEmpty(cards: Locator): Promise<boolean> {
  return cards.evaluateAll(elements =>
    elements.filter(el => el.getClientRects().length > 0).every(el => (el.textContent ?? '').trim().length > 0)
  )
}

async function openBotChat(page: Page, bot = 'alpha'): Promise<Locator> {
  const row = page.locator(`[data-slot="bots-roster"] [data-roster-key="local::${bot}"]`)

  if (!(await row.isVisible())) {
    await page
      .getByRole('button', { name: 'Bots', exact: true })
      .or(page.getByRole('tab', { name: 'Bots', exact: true }))
      .first()
      .click()
  }

  await expect(row).toBeVisible({ timeout: 30_000 })
  await row.click()

  const botSurface = page.locator('[data-chat-surface][data-bot-chat]').filter({ visible: true }).first()
  await expect(botSurface).toBeVisible({ timeout: 60_000 })

  return botSurface
}

async function expectOneNameAboveFailedCall(botSurface: Locator): Promise<void> {
  const response = botSurface.locator('[data-slot="aui_response-group"]').last()
  await expect(response.locator('[data-bubble="assistant"]').filter({ hasText: REPLY_MARKER }).first()).toBeVisible({
    timeout: 120_000
  })

  const names = response.locator('[data-slot="bot-reply-name"]').filter({ visible: true })
  await expect(names, 'the response opens one name label').toHaveCount(1)

  const nameBox = await names.first().boundingBox()
  const rowBox = await response.locator('[data-slot="tool-block"]').filter({ visible: true }).first().boundingBox()
  expect(nameBox!.y, 'the name label sits above the failed call').toBeLessThan(rowBox!.y)
}

async function watchNameLabels(page: Page): Promise<() => Promise<string[]>> {
  await page.evaluate(() => {
    const violations: string[] = []
    const seen = new Set<string>()
    const probe = window as unknown as { __nameLabelFrame?: number; __nameLabelViolations: string[] }
    const visible = (el: Element) => el.getClientRects().length > 0

    const sample = () => {
      const surface = [...document.querySelectorAll('[data-chat-surface][data-bot-chat]')].find(visible)
      const groups = surface?.querySelectorAll('[data-slot="aui_response-group"]')
      const group = groups?.[groups.length - 1]

      if (group) {
        const cards = [...group.querySelectorAll('[data-bubble="assistant"]')].filter(visible).length
        const names = [...group.querySelectorAll('[data-slot="bot-reply-name"]')].filter(visible).length
        const state = `cards=${cards} names=${names}`

        if (cards > 0 && names !== 1 && !seen.has(state)) {
          seen.add(state)
          violations.push(state)
        }
      }

      probe.__nameLabelFrame = requestAnimationFrame(sample)
    }

    if (probe.__nameLabelFrame !== undefined) {
      cancelAnimationFrame(probe.__nameLabelFrame)
    }

    probe.__nameLabelViolations = violations
    probe.__nameLabelFrame = requestAnimationFrame(sample)
  })

  return () => page.evaluate(() => (window as unknown as { __nameLabelViolations: string[] }).__nameLabelViolations)
}

async function sendInBotChat(botSurface: Locator, text: string): Promise<void> {
  const composer = botSurface.locator('[contenteditable="true"]').first()
  await composer.click()
  await composer.fill(text)
  await composer.press('Enter')
}

test.beforeAll(async () => {
  const mock = await startMockServer()
  const sandbox = createSandbox('bot-chat-reply-internals')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)

  const botHome = path.join(sandbox.hermesHome, 'profiles', 'alpha')
  fs.mkdirSync(botHome, { recursive: true })
  writeMockProviderConfig(botHome, mock.url)
  writeEnvFile(botHome)
  await seedChat(botHome, 'Bot Chat', PROMPT)
  await seedChat(sandbox.hermesHome, REGULAR_TITLE, PROMPT)

  for (const bot of [LIVE_BOT, FAILED_BOT, APPROVAL_BOT, RELOADED_FAILED_BOT]) {
    const home = path.join(sandbox.hermesHome, 'profiles', bot)
    fs.mkdirSync(home, { recursive: true })
    writeMockProviderConfig(
      home,
      mock.url,
      undefined,
      bot === APPROVAL_BOT ? 'approvals:\n  mode: "manual"\n' : undefined
    )
    writeEnvFile(home)
    await seedChat(home, 'Bot Chat', bot === RELOADED_FAILED_BOT ? FAILED_PROMPT : SEED_PROMPT)
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

test('regular chats keep the tool summary and the thinking block', async () => {
  test.setTimeout(180_000)
  const page = fixture!.page

  const toDefault = page.getByRole('button', { name: 'Switch to default' })

  if (await toDefault.isVisible()) {
    await toDefault.click()
  }

  await page.locator('[data-slot="sidebar"] button').filter({ hasText: REGULAR_TITLE }).first().click()

  const surface = page.locator('[data-chat-surface]:not([data-bot-chat])').filter({ visible: true }).first()
  await expect(surface.getByText(REPLY_MARKER).first(), 'the reply prose renders').toBeVisible({ timeout: 90_000 })

  await expect(
    surface.locator('[data-tool-summary]').filter({ visible: true }).first(),
    'regular chat shows the tool-run summary line'
  ).toBeVisible({ timeout: 30_000 })
  await expect(
    surface.locator('[data-slot="aui_thinking-disclosure"]').filter({ visible: true }).first(),
    'regular chat shows the thinking block'
  ).toBeVisible()
  await capture(page, 'regular-chat')
})

test('bot chat reply card shows only the reply prose', async () => {
  test.setTimeout(300_000)
  const page = fixture!.page

  const botSurface = await openBotChat(page)

  const cards = botSurface.locator('[data-bubble="assistant"]')
  await expect(cards.filter({ hasText: REPLY_MARKER }).first(), 'the reply prose renders in the card').toBeVisible({
    timeout: 90_000
  })

  await expect(botSurface.locator('[data-tool-summary]'), 'no tool-run summary line').toHaveCount(0)
  await expect(botSurface.locator('[data-slot="tool-block"]'), 'no tool call rows').toHaveCount(0)
  await expect(botSurface.locator('[data-slot="aui_thinking-disclosure"]'), 'no thinking block').toHaveCount(0)
  await expect(cards.getByText(THOUGHT), 'reasoning text is not rendered').toHaveCount(0)
  await expect(
    botSurface.getByText(/\b(ran|running|explored|read)\b.*\b(command|commands|file|files)\b/i),
    'no tool-run summary wording'
  ).toHaveCount(0)
  expect(await visibleCardsAreNonEmpty(cards), 'no reply card is left empty by the hidden parts').toBe(true)
  await expect(
    botSurface.locator('[data-slot="bot-reply-name"]').filter({ visible: true }),
    'one reply opens one name label'
  ).toHaveCount(1)
  await capture(page, 'bot-chat')
})

test('bot chat still shows a question the user has to answer', async () => {
  test.setTimeout(180_000)
  const page = fixture!.page
  const botSurface = await openBotChat(page)

  const composer = botSurface.locator('[contenteditable="true"]').first()
  await composer.click()
  await composer.type(SINGLE_BATCH_CLARIFY_TRIGGER, { delay: 20 })
  await page.keyboard.press('Enter')

  const card = botSurface.locator('form[data-clarify-batch]')
  await expect(card, 'the clarify card renders in the bot chat').toHaveCount(1, { timeout: 60_000 })
  await expect(card.getByText(SINGLE_BATCH_CLARIFY_QUESTIONS[0]!.question)).toBeVisible()
  await expect(botSurface.locator('[data-slot="tool-block"]'), 'still no tool call rows').toHaveCount(0)
  await capture(page, 'bot-chat-clarify')
})

test('a live bot reply that starts with tool calls shows exactly one name label', async () => {
  test.setTimeout(240_000)
  const page = fixture!.page
  const botSurface = await openBotChat(page, LIVE_BOT)

  const nameLabelViolations = await watchNameLabels(page)
  await sendInBotChat(botSurface, LIVE_PROMPT)

  const reply = botSurface.locator('[data-bubble="assistant"]').filter({ hasText: REPLY_MARKER }).first()
  await expect(reply, 'the live reply prose renders').toBeVisible({ timeout: 120_000 })

  const response = botSurface.locator('[data-slot="aui_response-group"]').last()
  const names = response.locator('[data-slot="bot-reply-name"]').filter({ visible: true })
  await expect(names, 'the live response opens one name label').toHaveCount(1)
  await expect(response.locator('[data-slot="tool-block"]'), 'no tool call rows in the live response').toHaveCount(0)

  const nameBox = await names.first().boundingBox()
  const replyBox = await reply.boundingBox()
  expect(nameBox!.y, 'the name label sits above the reply card').toBeLessThan(replyBox!.y)
  expect(await nameLabelViolations(), 'every painted frame with a reply card has exactly one name label').toEqual([])
  await capture(page, 'bot-chat-live-reply')
})

test('bot chat still shows a failed terminal call', async () => {
  test.setTimeout(240_000)
  const page = fixture!.page
  const botSurface = await openBotChat(page, FAILED_BOT)

  await sendInBotChat(botSurface, FAILED_PROMPT)

  const failedRow = botSurface.locator('[data-slot="tool-block"]').filter({ visible: true })
  await expect(failedRow.first(), 'the failed terminal call renders in the bot chat').toBeVisible({ timeout: 120_000 })
  await expect(failedRow.first()).toContainText(FAILED_PATH)
  await expect(botSurface.locator('[data-slot="aui_thinking-disclosure"]'), 'still no thinking block').toHaveCount(0)

  await expectOneNameAboveFailedCall(botSurface)
  await capture(page, 'bot-chat-failed-call')
})

test('bot chat still shows an approval prompt the user can act on', async () => {
  test.setTimeout(240_000)
  const page = fixture!.page
  const botSurface = await openBotChat(page, APPROVAL_BOT)

  const replies = botSurface.locator('[data-bubble="assistant"]').filter({ hasText: MOCK_REPLY })
  await expect(replies.first(), 'the seeded reply renders before the approval turn').toBeVisible({ timeout: 90_000 })
  const repliesBefore = await replies.count()

  await sendInBotChat(botSurface, APPROVAL_COMMAND_TRIGGER)

  const run = botSurface.locator('[data-approval-run]').filter({ visible: true })
  await expect(run, 'the approval prompt renders in the bot chat').toHaveCount(1, { timeout: 120_000 })
  await expect(botSurface.locator('[data-approval-deny]').filter({ visible: true })).toHaveCount(1)
  await capture(page, 'bot-chat-approval')

  await run.click()

  await expect(run, 'the prompt is gone once answered').toHaveCount(0, { timeout: 30_000 })
  await expect(replies, 'the approved turn finishes with a new reply').toHaveCount(repliesBefore + 1, {
    timeout: 120_000
  })
})

test('a reloaded bot reply that starts with a failed call shows one name label above it', async () => {
  test.setTimeout(240_000)
  const page = fixture!.page
  const botSurface = await openBotChat(page, RELOADED_FAILED_BOT)

  const failedRow = botSurface.locator('[data-slot="tool-block"]').filter({ visible: true })
  await expect(failedRow.first(), 'the failed call renders from history').toBeVisible({ timeout: 90_000 })
  await expectOneNameAboveFailedCall(botSurface)
  await capture(page, 'bot-chat-reloaded-failed-call')
})
