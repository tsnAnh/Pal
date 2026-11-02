import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'
import os from 'node:os'
import path from 'node:path'

const run = promisify(execFile)
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

export const APP_PATH = '/Applications/Hermes.app'
export const HERMES_HOME = path.join(os.homedir(), '.hermes')

export async function waitFor(check, { timeout = 60000, interval = 500, label = 'condition' } = {}) {
  const deadline = Date.now() + timeout
  for (;;) {
    const value = await check().catch(() => false)
    if (value) return value
    if (Date.now() > deadline) throw new Error(`timeout waiting for ${label}`)
    await sleep(interval)
  }
}

export async function quitApp(appName = 'Hermes') {
  await run('osascript', ['-e', `tell application "${appName}" to quit`]).catch(() => {})
  await waitFor(async () => {
    const { stdout } = await run('pgrep', ['-f', `${APP_PATH}/Contents/MacOS/Hermes( |$)`]).catch(() => ({ stdout: '' }))
    return stdout.trim() === ''
  }, { timeout: 30000, label: 'Hermes to quit' })
}

export async function launchApp({ debugPort, extraArgs = [], appPath = APP_PATH }) {
  const args = ['-n', '-a', appPath, '--args']
  if (debugPort) args.push(`--remote-debugging-port=${debugPort}`, '--remote-debugging-address=127.0.0.1')
  args.push(...extraArgs)
  await run('open', args)
  if (!debugPort) return
  await waitFor(async () => {
    const response = await fetch(`http://127.0.0.1:${debugPort}/json/list`)
    const targets = await response.json()
    return targets.some((target) => target.type === 'page' && target.url.startsWith('file://'))
  }, { timeout: 60000, label: 'debug port' })
}

export async function gatewayEndpoint() {
  const { stdout } = await run('lsof', ['-nP', '-iTCP', '-sTCP:LISTEN', '-a', '-p', String(await gatewayPid())])
  const ports = [...stdout.matchAll(/127\.0\.0\.1:(\d+) \(LISTEN\)/g)].map((match) => Number(match[1]))
  return ports
}

async function readGatewayRecord() {
  const { readFile } = await import('node:fs/promises')
  return waitFor(async () => JSON.parse(await readFile(path.join(HERMES_HOME, 'gateway.pid'), 'utf8')), { timeout: 120000, label: 'the gateway pid file' })
}

export async function gatewayPid() {
  return (await readGatewayRecord()).pid
}

export async function gatewayCheckout() {
  const record = await readGatewayRecord()
  const entry = record.argv.find((arg) => arg.endsWith('hermes_cli/main.py'))
  return entry ? path.dirname(path.dirname(entry)) : null
}

export async function gitState(checkout) {
  const git = (...args) => run('git', ['-C', checkout, ...args]).then(({ stdout }) => stdout.trim())
  const sha = await git('rev-parse', 'HEAD')
  const status = await git('status', '--porcelain')
  return { sha, dirty: status.length > 0, dirty_paths: status ? status.split('\n').length : 0 }
}

export async function listProfiles(repo) {
  const { stdout } = await run(path.join(repo, '.venv/bin/python'), ['-m', 'hermes_cli.main', 'profile', 'list'], { cwd: repo })
  return stdout
    .replace(/\x1b\[[0-9;]*m/g, '')
    .split('\n')
    .map((line) => line.replace(/^[\s◆]+/, '').split(/\s+/)[0])
    .filter((name) => name && !/^(Profile|─+)$/.test(name))
}

export async function profileExists(name) {
  const { access } = await import('node:fs/promises')
  return access(path.join(HERMES_HOME, 'profiles', name, 'config.yaml')).then(() => true, () => false)
}

export async function clearProfileResidue(name) {
  if (name !== 'ios-fixture') throw new Error('refusing to clear any directory other than the ios-fixture profile')
  if (await profileExists(name)) return false
  const { rm } = await import('node:fs/promises')
  await rm(path.join(HERMES_HOME, 'profiles', name), { recursive: true, force: true })
  return true
}

export { run, sleep, spawn }
