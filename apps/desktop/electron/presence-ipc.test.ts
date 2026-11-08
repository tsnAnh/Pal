import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

import { afterEach, beforeEach, expect, it, vi } from 'vitest'

import { deviceLabel, IDLE_THRESHOLD_SECONDS, loadOrCreateDeviceId, registerPresenceIpc } from './presence-ipc'

let dir: string

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'presence-ipc-'))
})

afterEach(() => {
  fs.rmSync(dir, { recursive: true, force: true })
})

function register(overrides: { platform?: NodeJS.Platform; idleState?: string; appVersion?: string } = {}) {
  const handlers = new Map<string, () => unknown>()
  const getSystemIdleState = vi.fn(() => overrides.idleState ?? 'active')

  registerPresenceIpc({
    appVersion: overrides.appVersion ?? '1.2.3',
    ipcMain: { handle: (channel: string, handler: () => unknown) => void handlers.set(channel, handler) } as never,
    platform: overrides.platform ?? 'darwin',
    powerMonitor: { getSystemIdleState } as never,
    userDataDir: dir
  })

  return { getSystemIdleState, handlers }
}

it('mints a wire-valid device id once and keeps it across launches', () => {
  const first = loadOrCreateDeviceId(dir)

  expect(first).toMatch(/^[A-Za-z0-9-]{8,64}$/)
  expect(loadOrCreateDeviceId(dir)).toBe(first)
})

it('replaces an unreadable or invalid identity file with a fresh valid id', () => {
  const file = path.join(dir, 'reach-device.json')

  for (const content of ['not json', JSON.stringify({ deviceId: 'short' }), JSON.stringify({ deviceId: 'has spaces and too long ......................................................' })]) {
    fs.writeFileSync(file, content)

    const id = loadOrCreateDeviceId(dir)

    expect(id).toMatch(/^[A-Za-z0-9-]{8,64}$/)
    expect(JSON.parse(fs.readFileSync(file, 'utf8')).deviceId).toBe(id)
  }
})

it('creates the user data directory when it does not exist yet', () => {
  const nested = path.join(dir, 'missing', 'userData')

  expect(loadOrCreateDeviceId(nested)).toMatch(/^[A-Za-z0-9-]{8,64}$/)
})

it.each([
  ['darwin', 'Desktop (macOS)'],
  ['win32', 'Desktop (Windows)'],
  ['linux', 'Desktop (Linux)'],
  ['freebsd', 'Desktop']
] as const)('labels %s generically as %s', (platform, label) => {
  expect(deviceLabel(platform)).toBe(label)
})

it('serves the identity with the persisted id, generic label and a wire-sized version', async () => {
  const { handlers } = register({ appVersion: 'v'.repeat(80), platform: 'win32' })
  const identity = (await handlers.get('hermes:presence:identity')!()) as Record<string, string>

  expect(identity.label).toBe('Desktop (Windows)')
  expect(identity.appVersion).toHaveLength(32)
  expect(identity.deviceId).toBe(loadOrCreateDeviceId(dir))
  expect(Object.keys(identity).sort()).toEqual(['appVersion', 'deviceId', 'label'])
})

it.each([
  ['active', false],
  ['unknown', false],
  ['idle', true],
  ['locked', true]
])('maps system idle state %s to %s', async (idleState, expected) => {
  const { getSystemIdleState, handlers } = register({ idleState })

  expect(await handlers.get('hermes:presence:idle')!()).toBe(expected)
  expect(getSystemIdleState).toHaveBeenCalledWith(IDLE_THRESHOLD_SECONDS)
})
