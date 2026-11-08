import { randomUUID } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

import type { IpcMain, PowerMonitor } from 'electron'

export interface PresenceIdentity {
  deviceId: string
  label: string
  appVersion: string
}

export interface PresenceIpcHost {
  ipcMain: Pick<IpcMain, 'handle'>
  powerMonitor: Pick<PowerMonitor, 'getSystemIdleState'>
  userDataDir: string
  appVersion: string
  platform?: NodeJS.Platform
}

const DEVICE_ID_RE = /^[A-Za-z0-9-]{8,64}$/
const IDENTITY_FILE = 'reach-device.json'
export const IDLE_THRESHOLD_SECONDS = 300
const APP_VERSION_MAX = 32

const PLATFORM_LABELS: Partial<Record<NodeJS.Platform, string>> = {
  darwin: 'Desktop (macOS)',
  linux: 'Desktop (Linux)',
  win32: 'Desktop (Windows)'
}

export function deviceLabel(platform: NodeJS.Platform): string {
  return PLATFORM_LABELS[platform] ?? 'Desktop'
}

function readDeviceId(filePath: string): string {
  try {
    const value = JSON.parse(fs.readFileSync(filePath, 'utf8'))?.deviceId

    return typeof value === 'string' && DEVICE_ID_RE.test(value) ? value : ''
  } catch {
    return ''
  }
}

function writeDeviceId(filePath: string, deviceId: string): void {
  const staging = `${filePath}.${process.pid}.tmp`

  fs.mkdirSync(path.dirname(filePath), { recursive: true })
  fs.writeFileSync(staging, JSON.stringify({ deviceId }), { mode: 0o600 })
  fs.renameSync(staging, filePath)
}

export function loadOrCreateDeviceId(userDataDir: string): string {
  const filePath = path.join(userDataDir, IDENTITY_FILE)
  const existing = readDeviceId(filePath)

  if (existing) {
    return existing
  }

  const created = randomUUID()
  writeDeviceId(filePath, created)

  return created
}

export function registerPresenceIpc({
  ipcMain,
  powerMonitor,
  userDataDir,
  appVersion,
  platform = process.platform
}: PresenceIpcHost): void {
  let identity: PresenceIdentity | null = null

  ipcMain.handle('hermes:presence:identity', (): PresenceIdentity => {
    identity ??= {
      appVersion: appVersion.slice(0, APP_VERSION_MAX),
      deviceId: loadOrCreateDeviceId(userDataDir),
      label: deviceLabel(platform)
    }

    return identity
  })

  ipcMain.handle('hermes:presence:idle', (): boolean => {
    const state = powerMonitor.getSystemIdleState(IDLE_THRESHOLD_SECONDS)

    return state === 'idle' || state === 'locked'
  })
}
