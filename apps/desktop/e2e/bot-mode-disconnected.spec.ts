import fs from 'node:fs'
import path from 'node:path'

import type { Locator, Page } from '@playwright/test'

import { writeEnvFile, writeMockProviderConfig } from '../../../tests-js/scripts/mock-provider-config'
import { startMockServer } from '../../../tests-js/scripts/mock-server'

import { buildAppEnv, createSandbox, launchDesktop, type MockBackendFixture, waitForAppReady } from './fixtures'
import { RealSessionBuilder } from './real-session-builder'
import { allowErrorBanners, expect, test } from './test'
import { VISUAL_WINDOW_HEIGHT, VISUAL_WINDOW_WIDTH } from './visual-snapshot'

const SCREEN_NAME = process.env.BOT_DISCONNECTED_SHOT ?? 'bots-only-disconnected'
const ARTIFACT_DIR = process.env.BOT_DISCONNECTED_DIR ?? '/tmp/grok-parity/screens/disconnected'
const ROW_CENTRE_Y = 26
const CONTROL_SIZE = 32
const TRAFFIC_LIGHT_ZONE = { height: 52, width: 80 }

let fixture: MockBackendFixture | null = null

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

async function centre(locator: Locator): Promise<{ height: number; width: number; y: number }> {
  const box = await locator.boundingBox()
  expect(box, 'control is laid out').not.toBeNull()

  return { height: box!.height, width: box!.width, y: box!.y + box!.height / 2 }
}

async function visibleIntersections(page: Page, zone: { height: number; width: number }): Promise<string[]> {
  return page.evaluate(({ height, width }) => {
    const hits: string[] = []

    for (const el of document.body.querySelectorAll<HTMLElement>('*')) {
      const style = getComputedStyle(el)

      if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0) {
        continue
      }

      const rect = el.getBoundingClientRect()

      if (rect.width === 0 || rect.height === 0 || rect.right <= 0 || rect.left >= width || rect.top >= height) {
        continue
      }

      if (rect.bottom <= 0 || el.closest('[data-window-chrome]')) {
        continue
      }

      const paints = (el.textContent ?? '').trim() !== '' && el.children.length === 0
      const isControl = el.matches('button, [role="button"], input, svg, img, canvas')

      if (paints || isControl) {
        hits.push(`${el.tagName.toLowerCase()}:${(el.textContent ?? '').trim().slice(0, 40)}:${el.getAttribute('aria-label') ?? ''}`)
      }
    }

    return hits
  }, zone)
}

test.beforeAll(async () => {
  test.setTimeout(300_000)
  const mock = await startMockServer({})
  const sandbox = createSandbox('bot-mode-disconnected')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)
  await seedBot(sandbox.hermesHome, mock.url, 'alpha')

  const { app, page } = await launchDesktop(buildAppEnv(sandbox))

  await app.evaluate(({ BrowserWindow }, size) => {
    BrowserWindow.getAllWindows()[0]?.setBounds({ x: 0, y: 0, ...size })
  }, { height: VISUAL_WINDOW_HEIGHT, width: Math.max(VISUAL_WINDOW_WIDTH, 1400) })

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

test('bots-only mode while the gateway is unreachable shows a calm empty state and a Retry control in the toolbar row', async () => {
  test.setTimeout(300_000)
  allowErrorBanners()
  const page = fixture!.page

  await page.addInitScript(() => {
    const NativeWebSocket = window.WebSocket
    const live = new Set<WebSocket>()
    const flags = window as unknown as { __blockGateway?: boolean; __dropGateway?: () => void }

    class TrackedWebSocket extends NativeWebSocket {
      constructor(url: string | URL, protocols?: string | string[]) {
        super(url, protocols)
        live.add(this)

        if (flags.__blockGateway) {
          queueMicrotask(() => this.close())
        }
      }
    }

    window.WebSocket = TrackedWebSocket as typeof WebSocket

    flags.__dropGateway = () => {
      flags.__blockGateway = true
      live.forEach(socket => socket.close())
    }
  })
  await page.reload()
  await waitForAppReady(fixture!, 120_000)

  await page
    .getByRole('button', { name: 'Bots', exact: true })
    .or(page.getByRole('tab', { name: 'Bots', exact: true }))
    .first()
    .click()
  await expect(page.locator('[data-slot="bots-roster"] [data-roster-key="local::alpha"]')).toBeVisible({
    timeout: 30_000
  })

  await page.getByRole('button', { name: 'New bot or group chat' }).filter({ visible: true }).first().click()
  await page.getByRole('menuitem', { name: 'Bots-only mode' }).click()
  await expect(page.getByRole('group', { name: 'Sidebar panes' })).toHaveCount(0)

  await page.evaluate(() => (window as unknown as { __dropGateway: () => void }).__dropGateway())
  await page.waitForTimeout(4000)

  await expect(page.getByText(/Hermes gateway is not connected/).filter({ visible: true })).toHaveCount(0)

  const plus = await centre(page.getByRole('button', { name: 'New bot or group chat' }).filter({ visible: true }).first())
  const retryButton = page.getByRole('button', { name: 'Retry' }).filter({ visible: true }).first()
  await expect(retryButton).toBeVisible()
  const retry = await centre(retryButton)

  for (const [name, control] of [['plus', plus], ['retry', retry]] as const) {
    expect(Math.abs(control.y - ROW_CENTRE_Y), `${name} centre y`).toBeLessThanOrEqual(1.5)
    expect(control.width, `${name} width`).toBe(CONTROL_SIZE)
    expect(control.height, `${name} height`).toBe(CONTROL_SIZE)
  }

  expect(await visibleIntersections(page, TRAFFIC_LIGHT_ZONE), 'traffic-light zone is empty').toEqual([])

  const title = page.getByText("Can't reach Hermes").filter({ visible: true }).first()
  await expect(title).toBeVisible()
  expect((await title.boundingBox())!.y).toBeGreaterThan(52)
  await expect(page.getByText('Reconnecting automatically…').filter({ visible: true }).first()).toBeVisible()

  fs.mkdirSync(ARTIFACT_DIR, { recursive: true })
  await page.screenshot({ path: path.join(ARTIFACT_DIR, `${SCREEN_NAME}.png`) })
})
