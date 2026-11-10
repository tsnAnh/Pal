import fs from 'node:fs'
import path from 'node:path'

import type { Locator, Page } from '@playwright/test'

import {
  buildAppEnv,
  createSandbox,
  launchDesktop,
  type MockBackendFixture,
  waitForAppReady
} from '../../../../apps/desktop/e2e/fixtures'
import { RealSessionBuilder } from '../../../../apps/desktop/e2e/real-session-builder'
import { expect, test } from '../../../../apps/desktop/e2e/test'
import { writeEnvFile, writeMockProviderConfig } from '../../../../tests-js/scripts/mock-provider-config'
import { MOCK_REPLY, startMockServer } from '../../../../tests-js/scripts/mock-server'

import { provisionHome } from './provision'

const EVIDENCE = path.join(process.env.VERIFY_RUN_DIR!, 'bot-mention-note')
const ASKER_BOT = 'asker'
const HELPER_BOT = 'helper'
const TYPED = `ask @${HELPER_BOT} to say hi`
const NOTE_HEAD = '[@mentions resolved from the Bot Mode roster'
const NOTE_LINE = `@${HELPER_BOT} = agent profile "${HELPER_BOT}"`

let fixture: MockBackendFixture | null = null

test.describe.configure({ mode: 'serial' })

function save(name: string, record: Record<string, unknown>): void {
  fs.writeFileSync(path.join(EVIDENCE, `${name}.json`), JSON.stringify(record, null, 2))
}

async function shot(page: Page, name: string): Promise<void> {
  await page.screenshot({ path: path.join(EVIDENCE, `${name}.png`) })
}

async function seedBot(hermesHome: string, mockUrl: string, bot: string): Promise<void> {
  const dir = path.join(hermesHome, 'profiles', bot)
  fs.mkdirSync(dir, { recursive: true })
  writeMockProviderConfig(dir, mockUrl)
  writeEnvFile(dir, undefined, mockUrl)
  const builder = await RealSessionBuilder.start(dir)

  try {
    await builder.createSession({ title: 'Bot Chat', turns: [`Hello ${bot}`] })
  } finally {
    await builder.close()
  }
}

async function openBotChat(page: Page, bot: string): Promise<Locator> {
  const row = page.locator(`[data-slot="bots-roster"] [data-roster-key="local::${bot}"]`)

  if (!(await row.isVisible())) {
    await page
      .getByRole('button', { name: 'Bots', exact: true })
      .or(page.getByRole('tab', { name: 'Bots', exact: true }))
      .first()
      .click()
  }

  await expect(row, `${bot} appears in the roster`).toBeVisible({ timeout: 30_000 })
  await row.click()

  const surface = page.locator('[data-chat-surface][data-bot-chat]').filter({ visible: true }).first()
  await expect(surface, `${bot} chat opens`).toBeVisible({ timeout: 60_000 })
  await expect(surface.getByText(`Hello ${bot}`, { exact: true }), `${bot}'s own history is on screen`).toBeVisible({
    timeout: 60_000
  })

  return surface
}

async function userBubbleTexts(surface: Locator): Promise<string[]> {
  return (await surface.locator('[data-bubble="user"]').allInnerTexts()).map(text => text.trim())
}

test.beforeAll(async () => {
  fs.mkdirSync(EVIDENCE, { recursive: true })

  const mock = await startMockServer()
  const sandbox = createSandbox('verify-bot-mention-note')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome, undefined, mock.url)

  const env = buildAppEnv(sandbox)

  provisionHome(env, sandbox.hermesHome)
  await seedBot(sandbox.hermesHome, mock.url, ASKER_BOT)
  await seedBot(sandbox.hermesHome, mock.url, HELPER_BOT)

  const { app, page } = await launchDesktop(env)

  await app.evaluate(({ BrowserWindow }) => {
    BrowserWindow.getAllWindows()[0]?.setBounds({ x: 0, y: 0, width: 1400, height: 900 })
  })

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
  await waitForAppReady(fixture, 240_000)
})

test.afterAll(async () => {
  await fixture?.cleanup()
  fixture = null
})

test('an @mention shows only what the owner typed while the model still gets the roster note', async () => {
  test.setTimeout(600_000)
  const page = fixture!.page
  const mock = fixture!.mock!
  const surface = await openBotChat(page, ASKER_BOT)
  await shot(page, '01-before-send')

  const promptsBefore = mock.receivedPrompts.length
  const replies = surface.locator('[data-bubble="assistant"]').filter({ hasText: MOCK_REPLY })
  const repliesBefore = await replies.count()
  const composer = surface.locator('[contenteditable="true"]').first()
  await composer.click()
  await composer.fill(TYPED)
  await composer.press('Enter')

  const bubble = surface.locator('[data-bubble="user"]').filter({ hasText: TYPED }).last()
  await expect(bubble, 'the owner bubble shows the typed sentence').toBeVisible({ timeout: 60_000 })
  await expect(replies, 'the turn finishes with a new reply').toHaveCount(repliesBefore + 1, { timeout: 120_000 })
  await shot(page, '02-after-reply')

  const bubbles = await userBubbleTexts(surface)
  expect(bubbles.at(-1), 'the bubble is exactly what was typed').toBe(TYPED)
  expect(await surface.innerText(), 'the roster note is nowhere on the surface').not.toContain(NOTE_HEAD)

  const turnPrompts = mock.receivedPrompts.slice(promptsBefore)
  const modelPrompt = turnPrompts.find(prompt => prompt.includes(TYPED)) ?? ''
  save('a-model-request', { typed: TYPED, bubbles, modelPrompt, promptsBefore, turnPrompts, allPrompts: mock.receivedPrompts })
  expect(modelPrompt, 'the model request starts with the typed sentence').toContain(TYPED)
  expect(modelPrompt, 'the model request carries the roster note').toContain(NOTE_HEAD)
  expect(modelPrompt, 'the note names the resolved agent').toContain(NOTE_LINE)

  await openBotChat(page, HELPER_BOT)
  const reopened = await openBotChat(page, ASKER_BOT)
  await expect(reopened.locator('[data-bubble="user"]').filter({ hasText: TYPED }).last()).toBeVisible({
    timeout: 60_000
  })
  const replayed = await userBubbleTexts(reopened)
  expect(replayed.at(-1), 'the stored transcript replays the typed sentence only').toBe(TYPED)
  expect(await reopened.innerText(), 'the replayed transcript carries no roster note').not.toContain(NOTE_HEAD)
  await shot(page, '03-after-reopen')
  save('b-replay', { replayedBubbles: replayed })
})
