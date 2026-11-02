#!/usr/bin/env node
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { clearProfileResidue, run, gatewayCheckout, gatewayPid, gitState, launchApp, listProfiles, profileExists, quitApp, sleep, waitFor } from './app.mjs'
import { Capture } from './capture.mjs'
import { CdpSession } from './cdp.mjs'
import { FixtureBuilder } from './fixtures.mjs'
import { MainHook } from './main-hook.mjs'
import { Redactor } from './redact.mjs'
import { PROFILE, SCENARIOS, deleteBotViaUi, openBotChat, prepareAssets } from './scenarios.mjs'
import { Ui } from './ui.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const iosRoot = path.resolve(here, '../..')
const repoRoot = path.resolve(iosRoot, '../..')
const fixturesDir = path.join(iosRoot, 'Fixtures')
const ASSETS_DIR = path.join(os.tmpdir(), 'ios-fixture-assets')
const RERUN = 'node apps/ios/Tools/record-fixtures/record.mjs'

const USAGE = `usage: ${RERUN} [options]

Records real Hermes desktop <-> gateway traffic for one Bot Mode session into
apps/ios/Fixtures/<scenario>.jsonl plus manifest.json. Needs /Applications/Hermes.app
and the live gateway. Creates, then deletes, only the "${PROFILE}" profile.

options:
  --only a,b          run only these scenarios (needs an existing ${PROFILE} bot unless open-bot is included)
  --attach PORT       drive an app already running with --remote-debugging-port=PORT (no quit/relaunch)
  --main-inspect PORT also hook the main process of an attached app (started with --inspect=PORT)
  --port PORT         debug port for the relaunched app (default 9333)
  --keep-profile      do not delete ${PROFILE} afterwards
  --keep-app          leave the debug-launched app running instead of relaunching it normally
  --no-write          run and report without writing fixtures
  --allow-driver-errors  write fixtures even when a scenario's driver failed (marked partial)
  --list              print scenario names
  --help
scenarios: ${SCENARIOS.map((s) => s.name).join(', ')}, profiles-list (derived)`

function parseArgs(argv) {
  const options = { port: 9333, mainInspect: 9340, only: null, attach: null, keepProfile: false, keepApp: false, write: true, allowDriverErrors: false }
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--only') options.only = argv[++i].split(',')
    else if (arg === '--attach') options.attach = Number(argv[++i])
    else if (arg === '--main-inspect') options.attachInspect = Number(argv[++i])
    else if (arg === '--port') options.port = Number(argv[++i])
    else if (arg === '--keep-profile') options.keepProfile = true
    else if (arg === '--keep-app') options.keepApp = true
    else if (arg === '--no-write') options.write = false
    else if (arg === '--allow-driver-errors') options.allowDriverErrors = true
    else if (arg === '--list') {
      console.log([...SCENARIOS.map((s) => s.name), 'profiles-list'].join('\n'))
      process.exit(0)
    } else if (arg === '--help' || arg === '-h') {
      console.log(USAGE)
      process.exit(0)
    } else throw new Error(`unknown option ${arg}\n${USAGE}`)
  }
  return options
}

async function secretValues() {
  const values = new Set()
  const env = await readFile(path.join(os.homedir(), '.hermes/.env'), 'utf8').catch(() => '')
  for (const line of env.split('\n')) {
    const value = line.split('=').slice(1).join('=').trim().replace(/^['"]|['"]$/g, '')
    if (value.length >= 12) values.add(value)
  }
  const auth = await readFile(path.join(os.homedir(), '.hermes/auth.json'), 'utf8').catch(() => '{}')
  const walk = (node) => {
    if (typeof node === 'string' && node.length >= 16 && !/\s/.test(node)) values.add(node)
    else if (node && typeof node === 'object') Object.values(node).forEach(walk)
  }
  try {
    walk(JSON.parse(auth))
  } catch {}
  return [...values]
}

async function identityWords() {
  const words = new Set([os.userInfo().username])
  const { stdout } = await run('git', ['config', '--get', 'user.email']).catch(() => ({ stdout: '' }))
  const email = stdout.trim().toLowerCase()
  if (email) {
    const [local, domain] = email.split('@')
    words.add(local)
    if (domain) words.add(domain.split('.')[0])
  }
  const { stdout: name } = await run('git', ['config', '--get', 'user.name']).catch(() => ({ stdout: '' }))
  if (name.trim()) words.add(name.trim().toLowerCase())
  return [...words].filter((word) => word.length >= 3)
}

const homeRelative = (value) => (value ? value.split(os.homedir()).join('~') : value)

async function gatewaySnapshot() {
  const checkout = await gatewayCheckout()
  return { pid: await gatewayPid(), checkout: homeRelative(checkout), git: checkout ? await gitState(checkout) : null }
}

function profilesListFixture(lines, startT) {
  const requests = new Map()
  for (const line of lines) {
    if (line.dir === 'send' && line.frame.method === 'profiles.list') requests.set(line.frame.id, line)
  }
  const responseLine = [...lines]
    .reverse()
    .find((line) => line.dir === 'recv' && requests.has(line.frame.id) && line.frame.result?.profiles?.[0]?.canonical_session)
  if (!responseLine) return []
  const request = requests.get(responseLine.frame.id)
  return [request, responseLine].map((line) => ({ ...line, t: Math.max(0, line.t - request.t) }))
}

async function main() {
  const options = parseArgs(process.argv.slice(2))
  const baseline = await listProfiles(repoRoot)
  console.log(`baseline profiles: ${baseline.join(', ')}`)
  const selected = SCENARIOS.filter((s) => !options.only || options.only.includes(s.name))
  const createsBot = selected.some((s) => s.name === 'open-bot')
  const gatewayStart = await gatewaySnapshot()

  const assets = await prepareAssets(ASSETS_DIR)
  const port = options.attach ?? options.port
  const inspectPort = options.attach ? options.attachInspect : options.mainInspect
  if (!options.attach) {
    await quitApp()
    await launchApp({
      debugPort: port,
      extraArgs: [
        `--inspect=${inspectPort}`,
        '--use-fake-ui-for-media-stream',
        '--use-fake-device-for-media-stream',
        `--use-file-for-fake-audio-capture=${assets.speech}`
      ]
    })
  }

  const cdp = await CdpSession.connect(port)
  const ui = new Ui(cdp)
  const version = await fetch(`http://127.0.0.1:${port}/json/version`).then((response) => response.json())
  const capture = new Capture(cdp)
  const hook = inspectPort ? await MainHook.attach(inspectPort, (entry) => capture.ingestIpc(entry)) : null
  await capture.start()
  await cdp.send('Page.reload')
  await ui.waitFor(
    `document.readyState==='complete'&&!!document.querySelector('[aria-label="New bot or group chat"]')&&document.querySelectorAll('button[aria-label*=" · @"]').length>0&&!/Reconnecting|CONNECTING/i.test(document.body.innerText)`,
    { timeout: 240000, label: 'connected roster' }
  )
  await sleep(4000)

  const results = []
  const ctx = { cdp, ui, capture, assets, state: {}, beforeCreate: () => clearProfileResidue(PROFILE) }
  const removeBot = async () => {
    await deleteBotViaUi(ctx)
    await waitFor(async () => !(await profileExists(PROFILE)), { timeout: 60000, label: `${PROFILE} profile to be removed` })
  }
  if (createsBot && baseline.includes(PROFILE)) {
    console.log(`removing stale ${PROFILE} through the app's Delete action`)
    await removeBot()
  }
  const gatewayRestarted = async () => {
    const pid = await gatewayPid().catch(() => null)
    return pid === gatewayStart.pid ? null : `gateway pid changed ${gatewayStart.pid} -> ${pid}`
  }
  const restartedBeforeRun = await gatewayRestarted()
  if (restartedBeforeRun) throw new Error(`stopping before any scenario: ${restartedBeforeRun}`)
  if (!createsBot) await openBotChat(ctx)
  for (const scenario of selected) {
    const mark = capture.mark()
    const startT = Date.now() - capture.epoch
    let partial = null
    console.log(`> ${scenario.name}`)
    try {
      const outcome = await scenario.run(ctx)
      if (outcome?.partial) partial = outcome.partial
      await sleep(1000)
    } catch (error) {
      partial = `driver error: ${error.message}`
      console.log(`  ! ${partial}`)
      await ui.screenshot(path.join(os.tmpdir(), `ios-fixture-${scenario.name}-failure.png`)).catch(() => {})
    }
    await hook?.drain()
    await capture.settle()
    results.push({ scenario, mark, end: capture.mark(), startT, endT: Date.now() - capture.epoch, partial })
    const restarted = await gatewayRestarted()
    if (restarted) {
      results.at(-1).partial = `driver error: ${restarted}`
      console.log(`stopping: ${restarted}`)
      break
    }
    if (scenario.name === 'open-bot' && partial) {
      console.log(`stopping: open-bot failed, later scenarios need the ${PROFILE} chat and would otherwise type into another bot`)
      break
    }
  }
  await hook?.detach()
  await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 }).catch(() => {})

  let failure = null
  try {
    if (process.env.FIXTURE_DEBUG_RAW) await writeFile(process.env.FIXTURE_DEBUG_RAW, JSON.stringify(capture.records))
    const otherBots = baseline.filter((name) => name !== 'default' && name !== PROFILE)
    const builder = new FixtureBuilder({
      profile: PROFILE,
      denyWords: [...otherBots, ...(await identityWords())],
      redactor: new Redactor({ extraSecrets: await secretValues(), maskWords: otherBots })
    })
    const allLines = builder.build(capture.records, 0)
    const outputs = new Map()
    for (const result of results) {
      outputs.set(result.scenario.name, builder.build(capture.records.slice(result.mark, result.end), result.startT))
    }
    const derived = profilesListFixture(allLines, 0)
    if (selected.length === SCENARIOS.length || options.only?.includes('profiles-list')) outputs.set('profiles-list', derived)

    const report = [...outputs].map(([name, lines]) => ({
      name,
      frames: lines.length,
      http: lines.filter((line) => line.channel === 'http').length,
      partial: results.find((result) => result.scenario.name === name)?.partial ?? (name === 'profiles-list' && !derived.length ? 'no canonical_session row observed' : null)
    }))
    console.table(report)
    const dropped = Object.fromEntries(builder.dropped)
    console.log(`filtered out (other bots, sessions, profiles): ${JSON.stringify(dropped)}`)

    const driverErrors = report.filter((row) => row.partial?.startsWith('driver error'))
    if (driverErrors.length && !options.allowDriverErrors) {
      options.write = false
      console.log(`not writing fixtures: driver errors in ${driverErrors.map((row) => row.name).join(', ')} (re-run, or pass --allow-driver-errors)`)
    }

    const leaks = builder.audit(JSON.stringify([...outputs.values()]))
    if (leaks.length) throw new Error(`redaction audit failed:\n${leaks.map((leak) => `  ${leak.word}: ${leak.context}`).join('\n')}`)

    const gatewayEnd = await gatewaySnapshot()
    if (options.write) {
      await mkdir(fixturesDir, { recursive: true })
      for (const [name, lines] of outputs) {
        await writeFile(path.join(fixturesDir, `${name}.jsonl`), lines.map((line) => JSON.stringify(line)).join('\n') + (lines.length ? '\n' : ''))
      }
      const repoGit = await gitState(repoRoot)
      const manifest = {
        recorded_at: new Date().toISOString(),
        rerun: RERUN,
        profile: PROFILE,
        app: { bundle: options.attach ? 'attached' : '/Applications/Hermes.app', electron: version['User-Agent']?.match(/Electron\/[\d.]+/)?.[0] ?? null },
        gateway: {
          at_start: gatewayStart,
          at_end: gatewayEnd,
          restarted_during_run: gatewayStart.pid !== gatewayEnd.pid,
          note: 'git.dirty is true when the checkout the gateway process runs from has uncommitted changes'
        },
        repo: { sha: repoGit.sha, dirty: repoGit.dirty, dirty_paths: repoGit.dirty_paths },
        line_schema: {
          t: 'ms since the scenario started',
          dir: 'send | recv; an http record is one line at request time with its response embedded',
          channel: 'ws | http',
          url_path: 'path only; query strings and credentials are dropped',
          frame: 'parsed JSON-RPC message, {"ws":{"event":...}} lifecycle marker, or {"http":{...}}'
        },
        capture_notes: [
          'ws frames come from CDP Network.webSocket* on the renderer',
          'http entries with via "electron-ipc hermes:api" are the renderer to main-process hermes:api calls (the main process issues the real HTTP to the gateway); the renderer itself issues no HTTP to the gateway',
          'composer attachments are staged to the profile cache by the main process; no wire frame carries the bytes on a local connection',
          'frames of other bots, sessions and profiles are filtered out; counts per kind are in filtered_out'
        ],
        filtered_out: dropped,
        scenarios: Object.fromEntries(
          [...outputs].map(([name, lines]) => {
            const result = results.find((entry) => entry.scenario.name === name)
            return [name, {
              file: `${name}.jsonl`,
              frames: lines.length,
              ws_frames: lines.filter((line) => line.channel === 'ws').length,
              http_calls: lines.filter((line) => line.channel === 'http').length,
              partial: Boolean(result?.partial) || (name === 'profiles-list' && !lines.length),
              partial_reason: result?.partial ?? (name === 'profiles-list' && !lines.length ? 'no canonical_session row observed' : null),
              duration_ms: result ? result.endT - result.startT : null
            }]
          })
        )
      }
      await writeFile(path.join(fixturesDir, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n')
      console.log(`wrote ${outputs.size} fixtures and manifest.json to ${fixturesDir}`)
    }
  } catch (error) {
    failure = error
  }

  if (!options.keepProfile && createsBot && (await profileExists(PROFILE))) {
    await removeBot()
    const after = await listProfiles(repoRoot)
    await clearProfileResidue(PROFILE)
    console.log(`profiles after: ${after.join(', ')}`)
    const same = JSON.stringify(after) === JSON.stringify(baseline.filter((name) => name !== PROFILE))
    console.log(same ? 'profiles match the baseline' : 'WARNING: profiles differ from the baseline')
    const gatewayAfter = await gatewayPid()
    console.log(gatewayAfter === gatewayStart.pid ? `gateway pid ${gatewayAfter} unchanged` : `WARNING: gateway pid changed ${gatewayStart.pid} -> ${gatewayAfter}`)
  }
  cdp.close()
  if (!options.attach && !options.keepApp) {
    await quitApp()
    await launchApp({})
    console.log('Hermes relaunched normally')
  }
  if (failure) throw failure
}

main().catch((error) => {
  console.error(error.message)
  process.exit(1)
})
