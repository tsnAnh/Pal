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
import { APPROVAL_COMMAND, APPROVAL_COMMAND_TRIGGER, MOCK_REPLY, startMockServer } from '../../../../tests-js/scripts/mock-server'

import { provisionHome } from './provision'

const EVIDENCE = path.join(process.env.VERIFY_RUN_DIR!, 'bot-chat-internals')
const APPROVER_BOT = 'approver'
const WORKER_BOT = 'worker'
const REGULAR_APPROVAL_TITLE = 'Verify Approval Session'
const REGULAR_TOOL_TITLE = 'Verify Toolrun Session'
const MANUAL_APPROVALS = 'approvals:\n  mode: "manual"\n'
const FAILED_PATH = '/e2e-missing-path-marker'
const OUTPUT_MARKER = 'VERIFY_OUT=42'
const COMMAND_MARKERS = ['echo VERIFY_OUT', '$((6*7))', `ls ${FAILED_PATH}`, FAILED_PATH]
const TOOL_PROMPT = `E2E_CALL(terminal)[{"command":"ls ${FAILED_PATH}"}] E2E_CALL(terminal)[{"command":"echo VERIFY_OUT=$((6*7))"}]`
const APPROVAL_TEXT = {
  bot: 'Needs your OK',
  botBody: 'This could change or delete something. Allow it?',
  gatewayDescription: 'delete in root path',
  regular: 'Command',
  show: 'Show details',
  hide: 'Hide details'
}

let fixture: MockBackendFixture | null = null

test.describe.configure({ mode: 'serial' })

function save(name: string, record: Record<string, unknown>): void {
  fs.writeFileSync(path.join(EVIDENCE, `${name}.json`), JSON.stringify(record, null, 2))
}

async function shot(page: Page, name: string): Promise<void> {
  await page.screenshot({ path: path.join(EVIDENCE, `${name}.png`) })
}

async function seedSession(home: string, title: string, turn: string): Promise<void> {
  const builder = await RealSessionBuilder.start(home)

  try {
    await builder.createSession({ title, turns: [turn] })
  } finally {
    await builder.close()
  }
}

async function seedBot(hermesHome: string, mockUrl: string, bot: string, extraConfig?: string): Promise<void> {
  const dir = path.join(hermesHome, 'profiles', bot)
  fs.mkdirSync(dir, { recursive: true })
  writeMockProviderConfig(dir, mockUrl, undefined, extraConfig)
  writeEnvFile(dir)
  await seedSession(dir, 'Bot Chat', `Hello ${bot}`)
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

async function openRegularChat(page: Page, title: string): Promise<Locator> {
  const botSurface = page.locator('[data-chat-surface][data-bot-chat]').filter({ visible: true })

  if (await botSurface.count()) {
    await page.locator('[data-slot="account-pill"]').filter({ visible: true }).click()
    await page
      .locator('[data-slot="account-menu"]')
      .getByRole('menuitem', { name: /^Sidebar panes/ })
      .click()
    await page.locator('[role^="menuitem"]').filter({ hasText: /^Sessions$/ }).click()
  }

  await page.locator('[data-slot="sidebar"] button').filter({ hasText: title }).first().click()

  const surface = page.locator('[data-chat-surface]:not([data-bot-chat])').filter({ visible: true }).first()
  await expect(surface.getByText(MOCK_REPLY).first(), 'the seeded regular reply renders').toBeVisible({ timeout: 90_000 })

  return surface
}

async function send(surface: Locator, text: string): Promise<void> {
  const composer = surface.locator('[contenteditable="true"]').first()
  await composer.click()
  await composer.fill(text)
  await composer.press('Enter')
}

async function watchBotInternals(page: Page, markers: string[]): Promise<() => Promise<string[]>> {
  await page.evaluate(sought => {
    const sightings = new Set<string>()
    const probe = window as unknown as { __internalsFrame?: number; __internalsSightings: string[] }

    const sample = () => {
      const surface = [...document.querySelectorAll('[data-chat-surface][data-bot-chat]')].find(
        el => el.getClientRects().length > 0
      )

      if (surface) {
        const text = [...surface.querySelectorAll('[data-slot="aui_response-group"]')]
          .map(group => group.textContent ?? '')
          .join('\n')

        for (const marker of sought) {
          if (text.includes(marker)) {
            sightings.add(`text:${marker}`)
          }
        }

        if (surface.querySelector('[data-slot="tool-block"], [data-tool-summary]')) {
          sightings.add('tool-row')
        }
      }

      probe.__internalsSightings = [...sightings]
      probe.__internalsFrame = requestAnimationFrame(sample)
    }

    if (probe.__internalsFrame !== undefined) {
      cancelAnimationFrame(probe.__internalsFrame)
    }

    probe.__internalsSightings = []
    probe.__internalsFrame = requestAnimationFrame(sample)
  }, markers)

  return () => page.evaluate(() => (window as unknown as { __internalsSightings: string[] }).__internalsSightings)
}

test.beforeAll(async () => {
  fs.mkdirSync(EVIDENCE, { recursive: true })

  const mock = await startMockServer()
  const sandbox = createSandbox('verify-bot-chat-internals')
  writeMockProviderConfig(sandbox.hermesHome, mock.url, undefined, MANUAL_APPROVALS)
  writeEnvFile(sandbox.hermesHome)

  const env = buildAppEnv(sandbox)

  provisionHome(env, sandbox.hermesHome)
  await seedSession(sandbox.hermesHome, REGULAR_APPROVAL_TITLE, REGULAR_APPROVAL_TITLE)
  await seedSession(sandbox.hermesHome, REGULAR_TOOL_TITLE, REGULAR_TOOL_TITLE)
  await seedBot(sandbox.hermesHome, mock.url, APPROVER_BOT, MANUAL_APPROVALS)
  await seedBot(sandbox.hermesHome, mock.url, WORKER_BOT)

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

test('bot chat approval speaks plainly, hides the command behind details, and still completes', async () => {
  test.setTimeout(600_000)
  const page = fixture!.page
  const record: Record<string, unknown> = {}
  const surface = await openBotChat(page, APPROVER_BOT)

  const replies = surface.locator('[data-bubble="assistant"]').filter({ hasText: MOCK_REPLY })
  await expect(replies.first(), 'the seeded reply renders before the approval turn').toBeVisible({ timeout: 90_000 })
  const repliesBefore = await replies.count()
  await shot(page, 'a-01-before-approval-turn')

  await send(surface, APPROVAL_COMMAND_TRIGGER)

  const card = surface.locator('[data-slot="tool-approval-card"]').filter({ visible: true })
  await expect(card, 'one approval card renders in the bot chat').toHaveCount(1, { timeout: 120_000 })
  await expect(card.getByText(APPROVAL_TEXT.bot, { exact: true }), 'header reads Needs your OK').toBeVisible()
  await expect(card.getByText(APPROVAL_TEXT.regular, { exact: true }), 'no Command header in bot chat').toHaveCount(0)
  await expect(card.locator('i.codicon-terminal'), 'no terminal icon in the bot approval header').toHaveCount(0)
  await expect(surface.getByText(APPROVAL_COMMAND), 'the raw command is not in the bot surface').toHaveCount(0)
  await expect(card.locator('pre'), 'no monospace block before details are opened').toHaveCount(0)
  await expect(card.getByText(APPROVAL_TEXT.botBody, { exact: true }), 'the card explains the ask in plain words').toBeVisible()
  await expect(card.getByText(APPROVAL_TEXT.gatewayDescription), 'the gateway risk label stays in details').toHaveCount(0)
  await shot(page, 'a-02-approval-card-collapsed')
  await card.screenshot({ path: path.join(EVIDENCE, 'a-02-approval-card-collapsed-card.png') })

  const surfaceTextCollapsed = await surface.innerText()
  expect(surfaceTextCollapsed, 'collapsed surface text carries no rm -rf').not.toContain('rm -rf')
  expect(surfaceTextCollapsed, 'collapsed surface text carries no probe path').not.toContain('hermes-e2e-approval-probe')
  record.collapsed = {
    cardText: await card.innerText(),
    commandInBotSurfaceDom: await surface.getByText(APPROVAL_COMMAND).count(),
    commandOnWholePage: await page.getByText(APPROVAL_COMMAND).count()
  }

  const details = card.locator('[data-slot="tool-approval-details"]')
  const showButton = details.getByRole('button', { name: APPROVAL_TEXT.show, exact: true })
  await expect(showButton, 'Show details toggle is offered').toBeVisible()
  await expect(showButton).toHaveAttribute('aria-expanded', 'false')

  await showButton.click()
  const hideButton = details.getByRole('button', { name: APPROVAL_TEXT.hide, exact: true })
  await expect(hideButton, 'the toggle now reads Hide details').toBeVisible()
  await expect(hideButton).toHaveAttribute('aria-expanded', 'true')
  await expect(card.getByText(APPROVAL_COMMAND), 'the command is visible after Show details').toBeVisible()
  await expect(card.getByText(APPROVAL_TEXT.gatewayDescription), 'the gateway risk label shows in details').toBeVisible()
  await shot(page, 'a-03-details-open')
  await card.screenshot({ path: path.join(EVIDENCE, 'a-03-details-open-card.png') })
  record.expanded = { ariaExpanded: await hideButton.getAttribute('aria-expanded'), command: APPROVAL_COMMAND }

  await hideButton.click()
  await expect(card.getByText(APPROVAL_COMMAND), 'the command is hidden again after Hide details').toHaveCount(0)
  await expect(details.getByRole('button', { name: APPROVAL_TEXT.show, exact: true })).toHaveAttribute(
    'aria-expanded',
    'false'
  )
  await shot(page, 'a-04-details-hidden-again')
  record.collapsedAgain = { ariaExpanded: await details.getByRole('button').getAttribute('aria-expanded') }

  await card.locator('[data-approval-run]').click()
  await expect(card, 'the card is gone once answered').toHaveCount(0, { timeout: 30_000 })
  await expect(replies, 'the approved turn finishes with a new reply').toHaveCount(repliesBefore + 1, {
    timeout: 120_000
  })
  await shot(page, 'a-05-after-approval-turn-complete')
  record.completed = { repliesBefore, repliesAfter: await replies.count() }
  save('a-approval', record)
})

test('bot chat tool turn shows only reply prose, never tool rows or commands', async () => {
  test.setTimeout(600_000)
  const page = fixture!.page
  const record: Record<string, unknown> = {}
  const surface = await openBotChat(page, WORKER_BOT)

  await expect(surface.locator('[data-bubble="assistant"]').filter({ hasText: MOCK_REPLY }).first()).toBeVisible({
    timeout: 90_000
  })
  await shot(page, 'b-01-before-tool-turn')

  const sightings = await watchBotInternals(page, COMMAND_MARKERS)
  await send(surface, TOOL_PROMPT)

  const reply = surface.locator('[data-bubble="assistant"]').filter({ hasText: OUTPUT_MARKER }).first()
  await expect(reply, 'reply prose carries the output of the last tool call').toBeVisible({ timeout: 180_000 })
  await page.waitForTimeout(1_500)
  await shot(page, 'b-02-after-tool-turn')

  await expect(surface.locator('[data-slot="tool-block"]'), 'no tool rows, including the failed ls call').toHaveCount(0)
  await expect(surface.locator('[data-tool-summary]'), 'no tool-run summary line').toHaveCount(0)

  const responseText = (await surface.locator('[data-slot="aui_response-group"]').allInnerTexts()).join('\n')

  for (const marker of COMMAND_MARKERS) {
    expect(responseText, `no command text "${marker}" in the bot replies`).not.toContain(marker)
  }

  const seen = await sightings()
  expect(seen, 'no tool row or command text was ever painted in a bot reply during the turn').toEqual([])
  record.toolTurn = {
    replyText: await reply.innerText(),
    responseText,
    toolBlocks: await surface.locator('[data-slot="tool-block"]').count(),
    toolSummaries: await surface.locator('[data-tool-summary]').count(),
    markersSearched: COMMAND_MARKERS,
    sightingsDuringTurn: seen
  }
  save('b-tool-turn', record)
})

test('regular chat approval keeps the Command header and the raw command with no toggle', async () => {
  test.setTimeout(600_000)
  const page = fixture!.page
  const record: Record<string, unknown> = {}
  const surface = await openRegularChat(page, REGULAR_APPROVAL_TITLE)
  await shot(page, 'c-01-regular-before-approval-turn')

  const replies = surface.locator('[data-bubble="assistant"]').filter({ hasText: MOCK_REPLY })
  const repliesBefore = await replies.count()
  await send(surface, APPROVAL_COMMAND_TRIGGER)

  const card = surface.locator('[data-slot="tool-approval-card"]').filter({ visible: true })
  await expect(card, 'one approval card renders in the regular chat').toHaveCount(1, { timeout: 120_000 })
  await expect(card.getByText(APPROVAL_TEXT.regular, { exact: true }), 'header reads Command').toBeVisible()
  await expect(card.getByText(APPROVAL_TEXT.bot, { exact: true }), 'no bot wording in regular chat').toHaveCount(0)
  await expect(card.locator('pre').filter({ hasText: APPROVAL_COMMAND }), 'raw command shown in a mono block').toBeVisible()
  await expect(card.locator('[data-slot="tool-approval-details"]'), 'no details toggle in regular chat').toHaveCount(0)
  await shot(page, 'c-02-regular-approval-card')
  await card.screenshot({ path: path.join(EVIDENCE, 'c-02-regular-approval-card-card.png') })
  record.approval = { cardText: await card.innerText(), toggles: await card.locator('[data-slot="tool-approval-details"]').count() }

  await card.locator('[data-approval-run]').click()
  await expect(card, 'the card is gone once answered').toHaveCount(0, { timeout: 30_000 })
  await expect(replies, 'the approved regular turn finishes with a new reply').toHaveCount(repliesBefore + 1, {
    timeout: 120_000
  })

  const toolSurface = await openRegularChat(page, REGULAR_TOOL_TITLE)
  await send(toolSurface, TOOL_PROMPT)
  await expect(
    toolSurface.locator('[data-bubble="assistant"]').filter({ hasText: OUTPUT_MARKER }).first(),
    'regular chat reply carries the same tool output'
  ).toBeVisible({ timeout: 180_000 })
  await expect(
    toolSurface.locator('[data-tool-summary]').filter({ visible: true }).first(),
    'control: the same tool turn is visible as a tool summary in regular chat'
  ).toBeVisible({ timeout: 30_000 })
  await shot(page, 'c-03-regular-tool-turn-control')
  record.control = { toolSummaries: await toolSurface.locator('[data-tool-summary]').filter({ visible: true }).count() }
  save('c-regular', record)
})
