import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

import type { Page } from '@playwright/test'

import { writeEnvFile, writeMockProviderConfig } from '../../../tests-js/scripts/mock-provider-config'
import { startMockServer } from '../../../tests-js/scripts/mock-server'

import { buildAppEnv, createSandbox, launchDesktop, type MockBackendFixture, waitForAppReady } from './fixtures'
import { expect, test } from './test'

const REPO_ROOT = path.resolve(import.meta.dirname, '..', '..', '..')
const PYTHON = path.join(REPO_ROOT, '.venv', 'bin', 'python')
const ARTIFACT_DIR = process.env.BOTS_SHARED_CATALOG_DIR ?? '/tmp/bots-shared-catalog-artifact'

test.use({ video: 'on', trace: 'on' })

let fixture: MockBackendFixture | null = null

function writeSkill(dir: string, name: string, connector?: string): void {
  const root = path.join(dir, 'skills', name)
  fs.mkdirSync(root, { recursive: true })
  const connectorLine = connector ? `connector: ${connector}\n` : ''

  fs.writeFileSync(
    path.join(root, 'SKILL.md'),
    `---\nname: ${name}\ndescription: Use when exercising ${name}.\n${connectorLine}---\n\n# ${name}\n\nFollow the ${name} routine.\n`,
    'utf8'
  )
}

function seedBot(hermesHome: string, mockUrl: string, name: string, extraConfig?: string): void {
  const dir = path.join(hermesHome, 'profiles', name)
  fs.mkdirSync(dir, { recursive: true })
  writeMockProviderConfig(dir, mockUrl, undefined, extraConfig)
  writeEnvFile(dir)
  writeSkill(dir, 'team-notes')
  writeSkill(dir, 'demo-helper', 'mcp:demo')
}

async function openBots(page: Page): Promise<void> {
  await expect(page.locator('div.fixed.inset-0[data-glass-opaque]')).toHaveCount(0, { timeout: 60_000 })
  await page
    .getByRole('button', { name: 'Bots', exact: true })
    .or(page.getByRole('tab', { name: 'Bots', exact: true }))
    .first()
    .click()
  await expect(page.getByRole('button', { name: 'New bot or group chat' })).toBeVisible()
}

async function openSkills(page: Page, bot: string) {
  await page.getByText(new RegExp(`^${bot}$`, 'i')).first().click({ button: 'right', timeout: 90_000 })
  await page.getByRole('menuitem', { name: 'Edit…' }).click()

  const dialog = page.getByRole('dialog')
  await dialog.getByRole('button', { name: /Advanced/ }).click()

  const search = dialog.getByPlaceholder(/Try/)
  await expect(search).toBeVisible({ timeout: 60_000 })

  return { dialog, search }
}

async function closeDialog(page: Page): Promise<void> {
  await page.getByRole('dialog').getByRole('button', { name: 'Close' }).first().click()
  await expect(page.getByRole('dialog')).toBeHidden()
}

test.beforeAll(async () => {
  test.setTimeout(300_000)
  fs.rmSync(ARTIFACT_DIR, { force: true, recursive: true })
  fs.mkdirSync(ARTIFACT_DIR, { recursive: true })

  const mock = await startMockServer({})
  const sandbox = createSandbox('bots-shared-catalog')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)

  const demoServer = [
    'mcp_servers:',
    '  demo:',
    `    command: ${JSON.stringify(PYTHON)}`,
    '    args: ["-c", "raise SystemExit(0)"]',
    '    enabled: true',
    ''
  ].join('\n')

  seedBot(sandbox.hermesHome, mock.url, 'scout', demoServer)
  seedBot(sandbox.hermesHome, mock.url, 'writer')

  const env = buildAppEnv(sandbox)
  execFileSync(PYTHON, ['-m', 'hermes_cli.main', 'catalog', 'migrate'], { cwd: REPO_ROOT, env, stdio: 'pipe' })

  const { app, page } = await launchDesktop(env)

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
  test.setTimeout(180_000)

  if (fixture) {
    await fixture.cleanup()
  }

  fixture = null
})

// eslint-disable-next-line no-empty-pattern
test('bots share one skills catalog; connector skills follow MCP; a new bot starts with skills off', async ({}, testInfo) => {
  test.setTimeout(300_000)
  const page = fixture!.page
  const home = fixture!.sandbox.hermesHome
  let step = 0

  await page.screencast.start({ path: path.join(ARTIFACT_DIR, 'flow.webm') })

  const shoot = async (name: string) => {
    step += 1
    const file = `${String(step).padStart(2, '0')}-${name}.png`
    const body = await page.screenshot()
    fs.writeFileSync(path.join(ARTIFACT_DIR, file), body)
    await testInfo.attach(file, { body, contentType: 'image/png' })
  }

  const skillRow = (dialog: ReturnType<Page['getByRole']>, name: string) =>
    dialog.getByText(name, { exact: true }).first()

  const find = async (search: ReturnType<Page['getByPlaceholder']>, name: string) => {
    await search.fill(name)
    await page.waitForTimeout(1500)
  }

  await openBots(page)
  await shoot('bots-roster')

  let ui = await openSkills(page, 'scout')
  await find(ui.search, 'team-notes')
  await expect(skillRow(ui.dialog, 'team-notes')).toBeVisible()
  await expect(ui.dialog.getByText('Shared', { exact: true }).first()).toBeVisible()
  await expect(ui.dialog.getByText('Local', { exact: true })).toHaveCount(0)
  await expect(ui.dialog.getByRole('switch').first()).toBeChecked()
  await shoot('scout-team-notes-listed')
  await find(ui.search, 'demo-helper')
  await expect(skillRow(ui.dialog, 'demo-helper')).toBeVisible()
  await shoot('scout-demo-helper-listed')
  await closeDialog(page)

  ui = await openSkills(page, 'writer')
  await find(ui.search, 'team-notes')
  await expect(skillRow(ui.dialog, 'team-notes')).toBeVisible()
  await shoot('writer-team-notes-listed')
  await find(ui.search, 'demo-helper')
  await expect(skillRow(ui.dialog, 'demo-helper')).toHaveCount(0)
  await shoot('writer-demo-helper-absent')
  await closeDialog(page)

  await page.getByRole('button', { name: 'New bot or group chat' }).click()
  await page.getByRole('menuitem', { name: 'New Bot' }).click()
  const newBot = page.getByRole('dialog', { name: 'New Bot' })
  await newBot.getByPlaceholder('inbox-triage').fill('helper')
  await newBot.getByPlaceholder('Inbox Triage').fill('Helper')
  await shoot('new-bot-dialog')
  await newBot.getByRole('button', { name: 'Create Bot' }).click()
  await expect(newBot).toBeHidden({ timeout: 60_000 })

  const helperDir = path.join(home, 'profiles', 'helper')
  await expect.poll(() => fs.existsSync(path.join(helperDir, 'config.yaml')), { timeout: 30_000 }).toBe(true)

  await openBots(page)
  ui = await openSkills(page, 'helper')
  await find(ui.search, 'team-notes')
  await expect(skillRow(ui.dialog, 'team-notes')).toBeVisible()
  await expect(ui.dialog.getByText('Shared', { exact: true }).first()).toBeVisible()
  await expect(ui.dialog.getByRole('switch').first()).not.toBeChecked()
  await shoot('helper-team-notes-off')
  await find(ui.search, 'demo-helper')
  await shoot('helper-demo-helper')
  await closeDialog(page)

  const config = fs.readFileSync(path.join(helperDir, 'config.yaml'), 'utf8')
  fs.writeFileSync(path.join(ARTIFACT_DIR, 'helper-config.yaml'), config)
  await page.screencast.stop()
  expect(config).not.toMatch(/^mcp_servers:\s*\S/m)
  expect(config).toMatch(/^model:/m)
  const memories = path.join(helperDir, 'memories')
  const memoryFiles = fs.existsSync(memories) ? fs.readdirSync(memories) : []
  expect(memoryFiles.filter(f => fs.statSync(path.join(memories, f)).size > 0)).toEqual([])
})
