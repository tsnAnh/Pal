import assert from 'node:assert/strict'

import { test } from 'vitest'

import { handleAppActivate } from './main-window-lifecycle'

const liveWindow = { isDestroyed: () => false }
const destroyedWindow = { isDestroyed: () => true }

test('a dock click with no primary window recreates it so the renderer boots through the last-chat restore', () => {
  const calls: string[] = []

  handleAppActivate(null, {
    activate: () => calls.push('activate'),
    createWindow: () => calls.push('create')
  })

  assert.deepEqual(calls, ['create'])
})

test('a destroyed primary window (app kept running after the window closed) is recreated, not activated', () => {
  const calls: string[] = []

  handleAppActivate(destroyedWindow, {
    activate: () => calls.push('activate'),
    createWindow: () => calls.push('create')
  })

  assert.deepEqual(calls, ['create'])
})

test('a live primary window is only brought forward and keeps whatever it shows', () => {
  const calls: string[] = []

  handleAppActivate(liveWindow, {
    activate: window => {
      assert.equal(window, liveWindow)
      calls.push('activate')
    },
    createWindow: () => calls.push('create')
  })

  assert.deepEqual(calls, ['activate'])
})
