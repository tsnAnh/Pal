import fs from 'node:fs'
import path from 'node:path'

import { writeEnvFile, writeMockProviderConfig } from '../../../../tests-js/scripts/mock-provider-config'
import { startMockServer } from '../../../../tests-js/scripts/mock-server'
import { buildAppEnv, createSandbox, launchDesktop, waitForAppReady } from '../../../../apps/desktop/e2e/fixtures'
import { test } from '../../../../apps/desktop/e2e/test'

import { provisionHome } from './provision'

const EVIDENCE = path.join(process.env.VERIFY_RUN_DIR!, 'startup-timing')
const WARM_RUNS = Number(process.env.STARTUP_WARM_RUNS || 3)
const BOOT_LINE = /^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d),(\d{3}) \[hermes\] (\[(?:boot|backend|gateway|env|updates)\][^\n]*)/

function bootPhases(log: string, since: number): { ms: number; line: string }[] {
  return log
    .split('\n')
    .map(line => BOOT_LINE.exec(line))
    .filter((match): match is RegExpExecArray => match !== null)
    .map(match => ({ at: new Date(`${match[1].replace(' ', 'T')}.${match[2]}`).getTime(), line: match[3].slice(0, 160) }))
    .filter(entry => entry.at >= since - 1000)
    .map(entry => ({ ms: entry.at - since, line: entry.line }))
}

test('cold and warm launch to a usable composer', async () => {
  fs.mkdirSync(EVIDENCE, { recursive: true })

  const mock = await startMockServer()
  const sandbox = createSandbox('startup-timing')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)

  const env = buildAppEnv(sandbox)

  provisionHome(env, sandbox.hermesHome)

  const runs: Record<string, unknown>[] = []
  const desktopLog = path.join(sandbox.hermesHome, 'logs', 'desktop.log')

  try {
    for (let index = 0; index <= WARM_RUNS; index++) {
      const kind = index === 0 ? 'cold-gateway' : 'warm-gateway'
      const spawned = Date.now()
      const { app, page } = await launchDesktop(env)
      const windowed = Date.now()
      const requests: { path: string; startMs: number; endMs?: number; status?: number }[] = []
      const open = new Map<object, (typeof requests)[number]>()
      const consoleLines: { ms: number; text: string }[] = []

      page.on('request', request => {
        const url = new URL(request.url())

        if (url.protocol.startsWith('http') && url.hostname === '127.0.0.1') {
          const entry = { path: `${request.method()} ${url.pathname}`, startMs: Date.now() - spawned }
          requests.push(entry)
          open.set(request, entry)
        }
      })
      page.on('requestfinished', async request => {
        const entry = open.get(request)

        if (entry) {
          entry.endMs = Date.now() - spawned
          entry.status = (await request.response())?.status()
        }
      })
      page.on('console', message => consoleLines.push({ ms: Date.now() - spawned, text: message.text().slice(0, 200) }))

      await page.waitForLoadState('domcontentloaded')
      const painted = Date.now()

      await page.evaluate(() => {
        const state = window as unknown as { __hbUsable?: number; __hbOverlayGone?: number }
        const tick = () => {
          const editor = document.querySelector<HTMLElement>('[data-slot="composer-root"] [contenteditable="true"]')
          const box = editor?.getBoundingClientRect()
          const hit = box && box.width > 0 ? document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2) : null

          if (editor && hit && (hit === editor || editor.contains(hit))) {
            state.__hbUsable = performance.now()

            return
          }

          requestAnimationFrame(tick)
        }

        requestAnimationFrame(tick)
      })

      await waitForAppReady({ app, page } as Parameters<typeof waitForAppReady>[0], 300_000)
      const ready = Date.now()
      const renderer = await page.evaluate(() => ({
        origin: performance.timeOrigin,
        marks: performance.getEntriesByType('mark').map(mark => ({ name: mark.name, at: mark.startTime })),
        usable: (window as unknown as { __hbUsable?: number }).__hbUsable ?? null,
        domContentLoaded: (performance.getEntriesByType('navigation')[0] as PerformanceNavigationTiming | undefined)?.domContentLoadedEventEnd ?? null
      }))

      runs.push({
        kind,
        spawnToWindowMs: windowed - spawned,
        spawnToDomContentLoadedMs: painted - spawned,
        spawnToComposerMs: ready - spawned,
        bootPhases: fs.existsSync(desktopLog) ? bootPhases(fs.readFileSync(desktopLog, 'utf8'), spawned) : [],
        requests,
        console: consoleLines,
        rendererOriginMs: Math.round(renderer.origin - spawned),
        rendererDomContentLoadedMs: renderer.domContentLoaded === null ? null : Math.round(renderer.origin + renderer.domContentLoaded - spawned),
        composerHitTestableMs: renderer.usable === null ? null : Math.round(renderer.origin + renderer.usable - spawned),
        rendererMarks: renderer.marks.map(mark => ({ name: mark.name, ms: Math.round(renderer.origin + mark.at - spawned) }))
      })
      await page.screenshot({ path: path.join(EVIDENCE, `${index}-${kind}-ready.png`) })
      await app.close()
    }
  } finally {
    fs.writeFileSync(path.join(EVIDENCE, 'timings.json'), JSON.stringify(runs, null, 2))

    for (const name of ['desktop.log', 'gateway.log', 'agent.log']) {
      const source = path.join(sandbox.hermesHome, 'logs', name)

      if (fs.existsSync(source)) {
        fs.copyFileSync(source, path.join(EVIDENCE, name))
      }
    }

    await mock.close()
    sandbox.cleanup()
  }
})
