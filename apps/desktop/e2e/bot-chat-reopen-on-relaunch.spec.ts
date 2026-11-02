import fs from 'node:fs'
import path from 'node:path'

import type { Page } from '@playwright/test'

import { writeEnvFile, writeMockProviderConfig } from '../../../tests-js/scripts/mock-provider-config'
import { startMockServer } from '../../../tests-js/scripts/mock-server'

import { buildAppEnv, createSandbox, launchDesktop, type MockBackendFixture, waitForAppReady } from './fixtures'
import { RealSessionBuilder } from './real-session-builder'
import { expect, test } from './test'
import { VISUAL_WINDOW_HEIGHT, VISUAL_WINDOW_WIDTH } from './visual-snapshot'

const ARTIFACT_DIR = '/tmp/reopen-last-chat'

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

function transcriptLine(page: Page, name: string) {
  return page.getByText(`Hello ${name}`, { exact: true }).filter({ visible: true }).first()
}

test('relaunching Desktop reopens the Bot Chat the owner last looked at', async () => {
  test.setTimeout(420_000)

  const mock = await startMockServer()
  const sandbox = createSandbox('reopen-last-chat')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)

  await seedBot(sandbox.hermesHome, mock.url, 'alpha')
  await seedBot(sandbox.hermesHome, mock.url, 'beta')

  const launch = async (): Promise<MockBackendFixture> => {
    const { app, page } = await launchDesktop(buildAppEnv(sandbox))

    await app.evaluate(
      ({ BrowserWindow }, size) => {
        BrowserWindow.getAllWindows()[0]?.setBounds({ x: 0, y: 0, ...size })
      },
      { width: Math.max(VISUAL_WINDOW_WIDTH, 1400), height: VISUAL_WINDOW_HEIGHT }
    )

    const fixture: MockBackendFixture = {
      app,
      cleanup: async () => void (await app.close().catch(() => undefined)),
      mock,
      mockUrl: mock.url,
      page,
      sandbox
    }

    await waitForAppReady(fixture, 120_000)

    return fixture
  }

  try {
    const first = await launch()

    await first.page
      .getByRole('button', { name: 'Bots', exact: true })
      .or(first.page.getByRole('tab', { name: 'Bots', exact: true }))
      .first()
      .click()

    await first.page.locator('[data-slot="bots-roster"] [data-roster-key="local::beta"]').click()
    await expect(transcriptLine(first.page, 'beta')).toBeVisible({ timeout: 60_000 })

    await first.page.locator('[data-slot="bots-roster"] [data-roster-key="local::alpha"]').click()
    await expect(transcriptLine(first.page, 'alpha')).toBeVisible({ timeout: 60_000 })

    await first.cleanup()

    const second = await launch()

    await expect(
      transcriptLine(second.page, 'alpha'),
      'the last-viewed Bot Chat is showing after relaunch'
    ).toBeVisible({
      timeout: 90_000
    })
    await expect(transcriptLine(second.page, 'beta')).toHaveCount(0)

    fs.mkdirSync(ARTIFACT_DIR, { recursive: true })
    await second.page.screenshot({ path: path.join(ARTIFACT_DIR, 'after.png') })

    await second.cleanup()
  } finally {
    await mock.close()
    sandbox.cleanup()
  }
})
