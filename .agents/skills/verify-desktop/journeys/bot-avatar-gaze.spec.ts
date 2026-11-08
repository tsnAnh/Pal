import fs from 'node:fs'
import path from 'node:path'

import type { Locator, Page } from '@playwright/test'

import { writeEnvFile, writeMockProviderConfig } from '../../../../tests-js/scripts/mock-provider-config'
import { startMockServer } from '../../../../tests-js/scripts/mock-server'
import {
  buildAppEnv,
  createSandbox,
  launchDesktop,
  type MockBackendFixture,
  waitForAppReady
} from '../../../../apps/desktop/e2e/fixtures'
import { RealSessionBuilder } from '../../../../apps/desktop/e2e/real-session-builder'
import { expect, test } from '../../../../apps/desktop/e2e/test'

import { provisionHome } from './provision'

const EVIDENCE = path.join(process.env.VERIFY_RUN_DIR!, 'bot-avatar-gaze')
const BOT = 'alpha'
const ROW = `[data-slot="bots-roster"] [data-roster-key="local::${BOT}"]`

interface EyeState {
  curve: null | string
  rest: string
  transform: string
}

let fixture: MockBackendFixture | null = null

async function seedBot(hermesHome: string, mockUrl: string): Promise<void> {
  const dir = path.join(hermesHome, 'profiles', BOT)
  fs.mkdirSync(dir, { recursive: true })
  writeMockProviderConfig(dir, mockUrl)
  writeEnvFile(dir)

  const builder = await RealSessionBuilder.start(dir)

  try {
    await builder.createSession({ title: 'Bot Chat', turns: [`Hello ${BOT}`] })
  } finally {
    await builder.close()
  }
}

async function eyes(face: Locator): Promise<EyeState[]> {
  return face.locator('[data-hb-eye]').evaluateAll(nodes =>
    nodes.map(node => ({
      curve: node.querySelector('path[data-hb-eye-curve]')?.getAttribute('d') ?? null,
      rest: node.getAttribute('data-hb-rest') ?? '',
      transform: node.getAttribute('transform') ?? ''
    }))
  )
}

function curvedWidth(eye: EyeState): number {
  const xs = Array.from((eye.curve ?? '').matchAll(/(-?[\d.]+) -?[\d.]+/g), point => Number(point[1]))

  return xs.length ? Math.max(...xs) - Math.min(...xs) : Number.NaN
}

function translateX(transform: string): number {
  return Number(/translate\(([-\d.]+)/.exec(transform)?.[1])
}

async function capture(page: Page, row: Locator, face: Locator, name: string, record: Record<string, unknown>) {
  const state = await eyes(face)

  record[name] = state.map(eye => ({ ...eye, curvedWidth: curvedWidth(eye) }))
  await row.screenshot({ path: path.join(EVIDENCE, `${name}-row.png`) })
  fs.writeFileSync(path.join(EVIDENCE, `${name}-face.svg`), await face.evaluate(node => node.outerHTML))

  return state
}

test.beforeAll(async () => {
  fs.mkdirSync(EVIDENCE, { recursive: true })

  const mock = await startMockServer()
  const sandbox = createSandbox('verify-gaze')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)

  const env = buildAppEnv(sandbox)

  provisionHome(env, sandbox.hermesHome)
  await seedBot(sandbox.hermesHome, mock.url)

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
  await waitForAppReady(fixture, 240_000)
})

test.afterAll(async () => {
  await fixture?.cleanup()
  fixture = null
})

test('roster avatar eyes turn around a sphere toward the pointer and settle back on leave', async () => {
  const page = fixture!.page
  const record: Record<string, unknown> = {}

  await page.emulateMedia({ reducedMotion: 'no-preference' })
  await page
    .getByRole('button', { name: 'Bots', exact: true })
    .or(page.getByRole('tab', { name: 'Bots', exact: true }))
    .first()
    .click()

  const row = page.locator(ROW)
  await expect(row, 'seeded bot appears in the roster').toBeVisible({ timeout: 30_000 })

  const face = row.locator('svg[data-bot-face]').first()
  await expect(face.locator('[data-hb-eye]'), 'face has two eyes').toHaveCount(2)
  await page.mouse.move(2, 2)
  await page.waitForTimeout(600)

  const idle = await capture(page, row, face, '01-idle', record)
  expect(idle.every(eye => eye.transform === eye.rest && eye.curve === null), 'eyes rest as baked pills before hover').toBe(true)

  const box = (await row.boundingBox())!
  const faceBox = (await face.boundingBox())!
  const midY = faceBox.y + faceBox.height / 2

  await page.mouse.move(box.x + box.width - 4, midY, { steps: 8 })
  await page.waitForTimeout(900)
  const right = await capture(page, row, face, '02-look-right', record)
  expect(right.every(eye => eye.curve !== null), 'both eyes are drawn as curved outlines while looking').toBe(true)
  expect(curvedWidth(right[1]), 'right eye curves around the side and narrows').toBeLessThan(curvedWidth(right[0]) * 0.85)
  expect(translateX(right[0].transform), 'eyes travel right').toBeGreaterThan(translateX(idle[0].rest))

  await page.mouse.move(box.x + 2, midY, { steps: 8 })
  await page.waitForTimeout(900)
  const left = await capture(page, row, face, '03-look-left', record)

  expect(curvedWidth(left[0]), 'left eye curves around the side when looking left').toBeLessThan(curvedWidth(left[1]) * 0.85)
  expect(translateX(left[0].transform), 'eyes travel left of the right look').toBeLessThan(translateX(right[0].transform))

  await page.mouse.move(box.x + box.width / 2, box.y + box.height + 160, { steps: 8 })
  await expect
    .poll(async () => (await eyes(face)).every(eye => eye.transform === eye.rest && eye.curve === null), {
      message: 'eyes return to the exact baked pose after the pointer leaves',
      timeout: 5_000
    })
    .toBe(true)
  await capture(page, row, face, '04-left-row', record)

  fs.writeFileSync(path.join(EVIDENCE, 'eyes.json'), JSON.stringify(record, null, 2))
})
