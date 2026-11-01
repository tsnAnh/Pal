import { afterEach, beforeEach, expect, it, vi } from 'vitest'

import { $botChromeless } from './bot-surface'
import { bindWindowChromeLayout } from './window-chrome-layout'

const setLayout = vi.fn()

beforeEach(() => {
  setLayout.mockClear()
  $botChromeless.set(false)
  window.hermesDesktop = { windowChrome: { setLayout } } as unknown as typeof window.hermesDesktop
})

afterEach(() => {
  delete (window as { hermesDesktop?: unknown }).hermesDesktop
})

it('requests relaxed on entering the chromeless bot surface and default on leaving', () => {
  const stop = bindWindowChromeLayout()

  $botChromeless.set(true)
  $botChromeless.set(false)

  expect(setLayout.mock.calls.map(([layout]) => layout)).toEqual(['default', 'relaxed', 'default'])
  stop()
})

it('does not repeat a layout the window already has', () => {
  const stop = bindWindowChromeLayout()

  $botChromeless.set(true)
  $botChromeless.set(true)
  stop()

  expect(setLayout.mock.calls.map(([layout]) => layout)).toEqual(['default', 'relaxed', 'default'])
})

it('restores default when unbound while relaxed', () => {
  const stop = bindWindowChromeLayout()

  $botChromeless.set(true)
  setLayout.mockClear()
  stop()

  expect(setLayout).toHaveBeenCalledExactlyOnceWith('default')
})

it('stays silent when the bridge is absent', () => {
  delete (window as { hermesDesktop?: unknown }).hermesDesktop
  const stop = bindWindowChromeLayout()

  expect(() => $botChromeless.set(true)).not.toThrow()
  stop()
})

it('resets a window left relaxed by a previous renderer on bind', () => {
  const stop = bindWindowChromeLayout()

  expect(setLayout).toHaveBeenCalledExactlyOnceWith('default')
  stop()
})

it('sends nothing on unbind when the window is already default', () => {
  const stop = bindWindowChromeLayout()

  setLayout.mockClear()
  stop()

  expect(setLayout).not.toHaveBeenCalled()
})
