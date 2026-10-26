import fs from 'node:fs'
import path from 'node:path'

import { writeEnvFile, writeMockProviderConfig } from '../../../tests-js/scripts/mock-provider-config'
import { startMockServer } from '../../../tests-js/scripts/mock-server'

import { buildAppEnv, createSandbox, launchDesktop, type MockBackendFixture, waitForAppReady } from './fixtures'
import { RealSessionBuilder } from './real-session-builder'
import { expect, test } from './test'
import { VISUAL_WINDOW_HEIGHT, VISUAL_WINDOW_WIDTH } from './visual-snapshot'

const ARTIFACT_DIR =
  process.env.BOT_HIDDEN_CHROME_SCREENSHOT_DIR ?? path.join(process.cwd(), 'test-results', 'bot-chat-hidden-chrome')

const CRON_HEADER = '[Cronjob "nightly-digest" output — scheduled job, not the user. Review it and summarize.]'
const CRON_BODY = 'CRON_OUTPUT_BODY_E2E'
const CRON_REPLY = 'CRON_REPLY_E2E: the nightly digest is handled.'
const BOT_GREETING = 'Hello alpha'
const REGULAR_TITLE = 'E2E Regular Rail Chat'
const REGULAR_PROMPTS = ['E2E_REGULAR_PROMPT_ONE', 'E2E_REGULAR_PROMPT_TWO']

let fixture: MockBackendFixture | null = null

test.beforeAll(async () => {
  const mock = await startMockServer({
    replyForPrompt: prompt => (prompt.includes(CRON_BODY) ? CRON_REPLY : 'E2E_PLAIN_REPLY')
  })

  const sandbox = createSandbox('bot-chat-hidden-chrome')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)

  const regular = await RealSessionBuilder.start(sandbox.hermesHome)

  try {
    await regular.createSession({ title: REGULAR_TITLE, turns: REGULAR_PROMPTS })
  } finally {
    await regular.close()
  }

  const botHome = path.join(sandbox.hermesHome, 'profiles', 'alpha')
  fs.mkdirSync(botHome, { recursive: true })
  writeMockProviderConfig(botHome, mock.url)
  writeEnvFile(botHome)

  const bot = await RealSessionBuilder.start(botHome)

  try {
    await bot.createSession({ title: 'Bot Chat', turns: [BOT_GREETING, `${CRON_HEADER}\n\n${CRON_BODY}`] })
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

test('regular chats keep the timeline rail', async () => {
  test.setTimeout(180_000)
  const page = fixture!.page

  const toDefault = page.getByRole('button', { name: 'Switch to default' })

  if (await toDefault.isVisible()) {
    await toDefault.click()
  }

  await page.locator('[data-slot="sidebar"] button').filter({ hasText: REGULAR_TITLE }).first().click()

  const transcript = page.locator('[data-slot="aui_thread-viewport"]').filter({ visible: true }).first()

  for (const prompt of REGULAR_PROMPTS) {
    await expect(transcript).toContainText(prompt, { timeout: 60_000 })
  }

  await expect(
    page.locator('[data-chat-surface]:not([data-bot-chat]) [data-slot="thread-timeline"]').filter({ visible: true }),
    'regular chat shows the timeline rail'
  ).toHaveCount(1, { timeout: 30_000 })
})

test('bot chats hide cron-job inbound turns and the timeline rail', async () => {
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

  await expect(botSurface.getByText(CRON_REPLY), 'the reply to the cron turn renders').toBeVisible({ timeout: 90_000 })
  await expect(botSurface.getByText(BOT_GREETING, { exact: true }), 'ordinary user turns still render').toBeVisible()

  await expect(
    botSurface.locator('[data-slot="aui_user-message-root"]'),
    'only the human turn has a user message'
  ).toHaveCount(1)
  await expect(botSurface.getByText(/Cronjob "nightly-digest"/), 'cron header is not rendered').toHaveCount(0)
  await expect(botSurface.getByText(/scheduled job, not the user/), 'cron header is not rendered').toHaveCount(0)
  await expect(botSurface.getByText(CRON_BODY), 'cron output body is not rendered').toHaveCount(0)

  await expect(
    botSurface.locator('[data-slot="thread-timeline"]'),
    'bot chats carry no timeline rail'
  ).toHaveCount(0)

  fs.mkdirSync(ARTIFACT_DIR, { recursive: true })
  await page.screenshot({ path: path.join(ARTIFACT_DIR, 'bot-chat.png') })
})
