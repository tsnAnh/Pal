import assert from 'node:assert/strict'

import { test } from 'vitest'

import { scrapeReadyPort, spawnLogPath } from './remote-lifecycle'

const OWNERSHIP_ID = '0123456789abcdef0123456789abcdef'
const SPAWN_NONCE = '0123456789abcdef'

function logSsh(log: string) {
  return {
    async exec(cmd: string) {
      return cmd.startsWith('cat ') ? log : ''
    }
  }
}

test('scrapeReadyPort explains a missing remote profile', async () => {
  const ssh = logSsh("Error: Profile 'operator' does not exist. Create it with: hermes profile create operator\n")

  await assert.rejects(
    () =>
      scrapeReadyPort(ssh, spawnLogPath(OWNERSHIP_ID, SPAWN_NONCE), {
        timeoutMs: 1000,
        isAlive: async () => false,
        profile: 'operator'
      }),
    (err: any) => {
      assert.equal(err.kind, 'remote-profile-missing')
      assert.equal(err.profile, 'operator')
      assert.match(err.message, /remote Hermes profile 'operator' does not exist/)
      assert.match(err.message, /hermes profile create operator/)

      return true
    }
  )
})

test('scrapeReadyPort normalizes the requested profile the way the CLI does', async () => {
  const ssh = logSsh("Error: Profile 'default' does not exist. Create it with: hermes profile create default\n")

  await assert.rejects(
    () => scrapeReadyPort(ssh, spawnLogPath(OWNERSHIP_ID, SPAWN_NONCE), { timeoutMs: 1000, profile: ' Default ' }),
    (err: any) => err.kind === 'remote-profile-missing' && err.profile === 'default'
  )
})

test("scrapeReadyPort ignores another profile's missing line and still reaches READY", async () => {
  const ssh = logSsh(
    "Profile 'chief' does not exist\nError: Profile 'chief' does not exist. Create it with: hermes profile create chief\nHERMES_DASHBOARD_READY port=4242\n"
  )

  assert.equal(await scrapeReadyPort(ssh, spawnLogPath(OWNERSHIP_ID, SPAWN_NONCE), { timeoutMs: 1000, profile: 'default' }), 4242)
})

test("scrapeReadyPort times out normally when only another profile's missing line is present", async () => {
  const ssh = logSsh("Error: Profile 'chief' does not exist. Create it with: hermes profile create chief\n")

  await assert.rejects(
    () => scrapeReadyPort(ssh, spawnLogPath(OWNERSHIP_ID, SPAWN_NONCE), { timeoutMs: 80, profile: 'default' }),
    (err: any) => err.kind === 'ready-timeout'
  )
})

test('scrapeReadyPort prefers READY over a stale line for the requested profile', async () => {
  const ssh = logSsh(
    "Error: Profile 'operator' does not exist. Create it with: hermes profile create operator\nHERMES_DASHBOARD_READY port=4243\n"
  )

  assert.equal(await scrapeReadyPort(ssh, spawnLogPath(OWNERSHIP_ID, SPAWN_NONCE), { timeoutMs: 1000, profile: 'operator' }), 4243)
})

test.each([
  ["lowercase", "error: profile 'operator' does not exist. create it with: hermes profile create operator\n"],
  ["indented", "  Error: Profile 'operator' does not exist. Create it with: hermes profile create operator\n"],
  ["prefixed", "2026-11-02 gateway: Error: Profile 'operator' does not exist. Create it with: hermes profile create operator\n"]
])('scrapeReadyPort does not match a %s variant of the missing-profile line', async (_label, log) => {
  await assert.rejects(
    () => scrapeReadyPort(logSsh(log), spawnLogPath(OWNERSHIP_ID, SPAWN_NONCE), { timeoutMs: 80, profile: 'operator' }),
    (err: any) => err.kind === 'ready-timeout'
  )
})

test('scrapeReadyPort keeps the generic spawn failure for other exits', async () => {
  const ssh = logSsh('Traceback (most recent call last):\nRuntimeError: boom\n')

  await assert.rejects(
    () =>
      scrapeReadyPort(ssh, spawnLogPath(OWNERSHIP_ID, SPAWN_NONCE), {
        timeoutMs: 1000,
        isAlive: async () => false
      }),
    (err: any) => {
      assert.equal(err.kind, 'spawn-failed')

      return true
    }
  )
})

test('scrapeReadyPort reports a missing remote profile without waiting for the ready timeout', async () => {
  const ssh = logSsh("Error: Profile 'operator' does not exist. Create it with: hermes profile create operator\n")
  const started = Date.now()

  await assert.rejects(
    () => scrapeReadyPort(ssh, spawnLogPath(OWNERSHIP_ID, SPAWN_NONCE), { timeoutMs: 60_000, profile: 'operator' }),
    (err: any) => {
      assert.equal(err.kind, 'remote-profile-missing')

      return true
    }
  )
  assert.ok(Date.now() - started < 5_000)
})
