import fs from 'node:fs'
import path from 'node:path'

import type { Locator, Page } from '@playwright/test'
import { PNG } from 'pngjs'

import { writeEnvFile, writeMockProviderConfig } from '../../../../tests-js/scripts/mock-provider-config'
import { type MockServer, startMockServer } from '../../../../tests-js/scripts/mock-server'
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

const EVIDENCE = path.join(process.env.VERIFY_RUN_DIR!, 'bot-avatar-loading')
const PENDING_PROBE = 'E2E_PENDING_PROBE'
const WHITE = '#f5f5f5'
const STRIP_SECONDS = 3
const TRACE_SECONDS = 24
const STRIP_FRAMES = 20
const STRIP_COLUMNS = 10
const STRIP_SCALE = 3

interface BotSeed {
  look: Record<string, unknown>
  name: string
}

const BOTS: BotSeed[] = [
  { look: {}, name: 'alpha' },
  { look: { color: WHITE, custom: true, shape: 'blobatar:snow' }, name: 'snow' },
  { look: { color: WHITE, custom: true, shape: 'squircle' }, name: 'pearl' },
  { look: { color: WHITE, custom: true, shape: 'sigil-3' }, name: 'rune' }
]

interface TraceFrame {
  dots: (null | string)[]
  eyes: (null | string)[]
  motion: boolean
  mood: null | string
  opacity: string
  t: number
  transform: string
}

let fixture: MockBackendFixture | null = null
const mocks = new Map<string, MockServer>()

const rowOf = (name: string) => `[data-slot="bots-roster"] [data-roster-key="local::${name}"]`

async function seedBot(hermesHome: string, mockUrl: string, { look, name }: BotSeed): Promise<void> {
  const dir = path.join(hermesHome, 'profiles', name)
  fs.mkdirSync(dir, { recursive: true })
  writeMockProviderConfig(dir, mockUrl)
  writeEnvFile(dir)

  if (Object.keys(look).length > 0) {
    fs.writeFileSync(
      path.join(dir, 'profile.yaml'),
      `ui_meta:\n  hermes-bots:\n${Object.entries(look)
        .map(([key, value]) => `    ${key}: ${JSON.stringify(value)}\n`)
        .join('')}`
    )
  }

  const builder = await RealSessionBuilder.start(dir)

  try {
    await builder.createSession({ title: 'Bot Chat', turns: [`Hello ${name}`] })
  } finally {
    await builder.close()
  }
}

test.beforeAll(async () => {
  fs.mkdirSync(EVIDENCE, { recursive: true })

  const sandbox = createSandbox('verify-loading')
  const homeMock = await startMockServer()
  writeMockProviderConfig(sandbox.hermesHome, homeMock.url)
  writeEnvFile(sandbox.hermesHome)

  const env = buildAppEnv(sandbox)

  provisionHome(env, sandbox.hermesHome)

  for (const bot of BOTS) {
    const mock = await startMockServer({ holdBeforeFirstTokenForPrompt: PENDING_PROBE })

    mocks.set(bot.name, mock)
    await seedBot(sandbox.hermesHome, mock.url, bot)
  }

  const { app, page } = await launchDesktop(env)

  fixture = {
    app,
    page,
    mock: homeMock,
    mockUrl: homeMock.url,
    sandbox,
    cleanup: async () => {
      await app.close().catch(() => undefined)
      await homeMock.close()
      await Promise.all([...mocks.values()].map(mock => mock.close()))
      sandbox.cleanup()
    }
  }
  await waitForAppReady(fixture, 240_000)
})

test.afterAll(async () => {
  await fixture?.cleanup()
  fixture = null
})

async function openRoster(page: Page): Promise<void> {
  if (await page.locator('[data-slot="bots-roster"]').first().isVisible()) {
    return
  }

  await page
    .getByRole('button', { name: 'Bots', exact: true })
    .or(page.getByRole('tab', { name: 'Bots', exact: true }))
    .first()
    .click()
}

async function faceState(face: Locator) {
  return face.evaluate(svg => ({
    dots: Array.from(svg.querySelectorAll('[data-hb-dot]'), dot => dot.getAttribute('opacity')),
    eyes: Array.from(svg.querySelectorAll('[data-hb-eye] path'), path => path.getAttribute('d')),
    motion: svg.hasAttribute('data-hb-motion'),
    mood: svg.getAttribute('data-hb-mood'),
    opacity: (svg as SVGSVGElement).style.opacity,
    tone: svg.getAttribute('data-hb-tone'),
    transform: (svg as SVGSVGElement).style.transform,
    transforms: Array.from(svg.querySelectorAll('[data-hb-eye]'), eye => eye.getAttribute('transform'))
  }))
}

async function faceColors(face: Locator) {
  return face.evaluate(svg => {
    const fill = (selector: string) => {
      const node = svg.querySelector(selector)

      return node ? getComputedStyle(node).fill : null
    }

    return {
      body: fill('[data-hb-body]'),
      dot: fill('[data-hb-dot]'),
      eye: fill('[data-hb-eye] path'),
      stroke: (() => {
        const node = svg.querySelector('[data-hb-body]')

        return node ? getComputedStyle(node).stroke : null
      })(),
      theme: document.documentElement.classList.contains('dark') ? 'dark' : 'light'
    }
  })
}

async function recordTrace(face: Locator, seconds: number): Promise<TraceFrame[]> {
  return face.evaluate(
    (svg, ms) =>
      new Promise<TraceFrame[]>(resolve => {
        const frames: TraceFrame[] = []
        let start = -1

        const tick = (now: number) => {
          start = start < 0 ? now : start
          frames.push({
            dots: Array.from(svg.querySelectorAll('[data-hb-dot]'), dot => dot.getAttribute('opacity')),
            eyes: Array.from(svg.querySelectorAll('[data-hb-eye] path'), path => path.getAttribute('d')),
            motion: svg.hasAttribute('data-hb-motion'),
            mood: svg.getAttribute('data-hb-mood'),
            opacity: (svg as SVGSVGElement).style.opacity,
            t: now - start,
            transform: (svg as SVGSVGElement).style.transform
          })

          if (now - start < ms) {
            requestAnimationFrame(tick)
          } else {
            resolve(frames)
          }
        }

        requestAnimationFrame(tick)
      }),
    seconds * 1000
  )
}

async function captureFrames(page: Page, face: Locator, seconds: number): Promise<{ at: number; png: Buffer }[]> {
  const pad = 8
  const frames: { at: number; png: Buffer }[] = []
  const start = Date.now()

  while (Date.now() - start < seconds * 1000) {
    const box = (await face.boundingBox())!
    const clip = { height: box.height + pad * 2, width: box.width + pad * 2, x: box.x - pad, y: box.y - pad }

    frames.push({ at: Date.now() - start, png: await page.screenshot({ clip }) })
  }

  return frames
}

function writeStrip(frames: { png: Buffer }[], file: string): { frames: number; height: number; width: number } {
  const picked = Array.from({ length: Math.min(STRIP_FRAMES, frames.length) }, (_, index) =>
    PNG.sync.read(frames[Math.floor((index * frames.length) / Math.min(STRIP_FRAMES, frames.length))].png)
  )

  const cell = picked[0]
  const columns = Math.min(STRIP_COLUMNS, picked.length)
  const rows = Math.ceil(picked.length / columns)
  const width = cell.width * STRIP_SCALE
  const height = cell.height * STRIP_SCALE
  const sheet = new PNG({ height: height * rows, width: width * columns })

  picked.forEach((frame, index) => {
    const left = (index % columns) * width
    const top = Math.floor(index / columns) * height

    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const from = ((Math.floor(y / STRIP_SCALE) * frame.width + Math.floor(x / STRIP_SCALE)) * 4) | 0
        const to = (((top + y) * sheet.width + left + x) * 4) | 0

        sheet.data[to] = frame.data[from]
        sheet.data[to + 1] = frame.data[from + 1]
        sheet.data[to + 2] = frame.data[from + 2]
        sheet.data[to + 3] = frame.data[from + 3]
      }
    }
  })
  fs.writeFileSync(file, PNG.sync.write(sheet))

  return { frames: picked.length, height: sheet.height, width: sheet.width }
}

function distinct<T>(values: T[]): number {
  return new Set(values.map(value => JSON.stringify(value))).size
}

function summarize(trace: TraceFrame[]) {
  const moved = trace.slice(1).filter((frame, index) => {
    return JSON.stringify([frame.eyes, frame.transform]) !== JSON.stringify([trace[index].eyes, trace[index].transform])
  }).length

  return {
    distinctBodyTransforms: distinct(trace.map(frame => frame.transform)),
    distinctDots: distinct(trace.map(frame => frame.dots)),
    distinctEyePoses: distinct(trace.map(frame => frame.eyes)),
    frames: trace.length,
    framesThatMoved: moved,
    seconds: trace[trace.length - 1].t / 1000
  }
}

async function exerciseLoading(page: Page, name: string, tag: string, record: Record<string, unknown>) {
  const dir = path.join(EVIDENCE, tag)
  fs.mkdirSync(dir, { recursive: true })

  const row = page.locator(rowOf(name))
  const face = row.locator('svg[data-bot-face]').first()
  const mock = mocks.get(name)!

  await expect(row, `${name} appears in the roster`).toBeVisible({ timeout: 30_000 })
  await row.click()
  await expect(page.getByText(`Hello ${name}`, { exact: true }).filter({ visible: true }).first()).toBeVisible({
    timeout: 60_000
  })
  await page
    .getByText(/Waking up/i)
    .first()
    .waitFor({ state: 'hidden', timeout: 90_000 })
    .catch(() => undefined)

  await page.mouse.move(2, 2)
  await expect
    .poll(
      async () =>
        face.evaluate(svg =>
          Array.from(svg.querySelectorAll('[data-hb-eye]')).every(eye => eye.getAttribute('transform') === eye.getAttribute('data-hb-rest'))
        ),
      { message: `${name} eyes finished easing back from the pointer`, timeout: 10_000 }
    )
    .toBe(true)
  await page.waitForTimeout(300)

  const before = await faceState(face)

  expect(before.mood, `${name} idles before the turn`).toBe('idle')
  expect(before.motion).toBe(false)
  await row.screenshot({ path: path.join(dir, '01-idle-row.png') })

  const editor = page.locator('[data-chat-surface][data-bot-chat] [contenteditable="true"]').filter({ visible: true }).first()

  await editor.click()
  await editor.fill(PENDING_PROBE)
  await page.keyboard.press('Enter')
  await mock.waitForHeldStream()

  await expect
    .poll(async () => (await faceState(face)).mood, { message: `${name} row face reports a working mood`, timeout: 15_000 })
    .toBe('think')
  await expect
    .poll(async () => (await faceState(face)).motion, { message: 'the loading clips took over the face', timeout: 10_000 })
    .toBe(true)

  await page.waitForTimeout(700)
  await row.screenshot({ path: path.join(dir, '02-loading-row.png') })

  const frames = await captureFrames(page, face, STRIP_SECONDS)

  fs.mkdirSync(path.join(dir, 'frames'), { recursive: true })
  frames.forEach((frame, index) => fs.writeFileSync(path.join(dir, 'frames', `${String(index).padStart(3, '0')}.png`), frame.png))
  const strip = writeStrip(frames, path.join(dir, 'strip.png'))
  const trace = await recordTrace(face, TRACE_SECONDS)
  const summary = summarize(trace)

  fs.writeFileSync(path.join(dir, 'trace.json'), JSON.stringify(trace))
  record[tag] = { before: before.eyes.length, screenshots: frames.length, strip, trace: summary }

  expect(frames.length, 'captured frames over three seconds').toBeGreaterThan(10)
  expect(summary.distinctEyePoses, `${name} eyes keep changing pose`).toBeGreaterThan(200)
  expect(summary.framesThatMoved, 'the pose changes on most frames').toBeGreaterThan(summary.frames * 0.5)
  expect(summary.distinctBodyTransforms, `${name} body moves in some clips`).toBeGreaterThan(5)
  expect(distinct(frames.map(frame => frame.png.toString('base64'))), 'screenshots differ frame to frame').toBeGreaterThan(8)

  mock.releaseHeldStream()
  await expect
    .poll(async () => (await faceState(face)).mood, { message: `${name} face goes idle after the turn`, timeout: 30_000 })
    .toBe('idle')
  await expect
    .poll(async () => (await faceState(face)).motion, { message: 'the clips release the face', timeout: 10_000 })
    .toBe(false)

  const after = await faceState(face)

  expect(after.eyes, `${name} eyes end exactly on the static render`).toEqual(before.eyes)
  expect(after.transforms).toEqual(before.transforms)
  expect(after.dots).toEqual(before.dots)
  expect(after.transform === '' || after.transform.startsWith('rotate('), 'no clip transform is left on the face').toBe(true)
  expect(after.opacity).toBe('')
  await row.screenshot({ path: path.join(dir, '03-idle-again-row.png') })
}

test('a working bot plays its loading clips, changes clips, and settles back on idle', async () => {
  const page = fixture!.page
  const record: Record<string, unknown> = {}

  await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'no-preference' })
  await openRoster(page)
  await exerciseLoading(page, 'alpha', 'alpha-blob', record)
  fs.writeFileSync(path.join(EVIDENCE, 'loading.json'), JSON.stringify(record, null, 2))
})

for (const [name, kind] of [
  ['snow', 'blob'],
  ['pearl', 'math'],
  ['rune', 'sigil']
] as const) {
  test(`a working white ${kind} bot plays its loading clips on the light theme`, async () => {
    const page = fixture!.page
    const record: Record<string, unknown> = {}

    await page.emulateMedia({ colorScheme: 'light', reducedMotion: 'no-preference' })
    await openRoster(page)
    await exerciseLoading(page, name, `${name}-${kind}-light`, record)
    fs.writeFileSync(path.join(EVIDENCE, `loading-${name}.json`), JSON.stringify(record, null, 2))
  })
}

test('a white bot is drawn dark on the light theme and unchanged on the dark theme', async () => {
  const page = fixture!.page
  const record: Record<string, unknown> = {}
  const dir = path.join(EVIDENCE, 'white-tone')
  fs.mkdirSync(dir, { recursive: true })

  await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'no-preference' })
  await openRoster(page)
  await page.mouse.move(2, 2)

  for (const scheme of ['dark', 'light'] as const) {
    await page.emulateMedia({ colorScheme: scheme, reducedMotion: 'no-preference' })
    await expect
      .poll(async () => page.evaluate(() => document.documentElement.classList.contains('dark')), {
        message: `${scheme} theme applies`,
        timeout: 15_000
      })
      .toBe(scheme === 'dark')
    await page.waitForTimeout(600)

    for (const { name } of BOTS) {
      const row = page.locator(rowOf(name))
      const face = row.locator('svg[data-bot-face]').first()

      await expect(face).toBeVisible({ timeout: 15_000 })
      record[`${scheme}-${name}`] = { ...(await faceColors(face)), tone: await face.getAttribute('data-hb-tone') }
      await row.screenshot({ path: path.join(dir, `${scheme}-${name}-row.png`) })
      fs.writeFileSync(path.join(dir, `${scheme}-${name}-face.svg`), await face.evaluate(node => node.outerHTML))
    }
  }

  fs.writeFileSync(path.join(dir, 'colors.json'), JSON.stringify(record, null, 2))

  const colors = record as Record<string, { body: null | string; dot: null | string; eye: null | string; tone: null | string }>
  const dark = 'rgb(27, 27, 27)'
  const light = 'rgb(243, 244, 253)'

  expect(colors['light-alpha'].tone, 'a coloured bot is not marked white').toBeNull()
  expect(colors['dark-alpha'].body, 'the coloured bot is the same on both themes').toBe(colors['light-alpha'].body)

  for (const name of ['snow', 'pearl', 'rune']) {
    expect(colors[`light-${name}`].tone, `${name} is marked white`).toBe('white')
    expect(colors[`dark-${name}`].tone).toBe('white')
    expect(colors[`dark-${name}`].body, `${name} keeps its white body on the dark theme`).not.toBe(dark)
    expect(colors[`dark-${name}`].eye, `${name} keeps its eyes on the dark theme`).not.toBe(light)
  }

  for (const name of ['snow', 'pearl']) {
    expect(colors[`light-${name}`].body, `${name} body turns near-black on the light theme`).toBe(dark)
    expect(colors[`light-${name}`].eye, `${name} eyes turn light on the light theme`).toBe(light)
  }

  expect(colors['light-pearl'].dot, 'pearl dots turn near-black on the light theme').toBe(dark)
  expect(colors['light-rune'].eye, 'sigil eyes stay visible on the light theme').toBe(dark)
})
