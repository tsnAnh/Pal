import { expect, test, vi } from 'vitest'

import { registerWindowChromeLayout, WINDOW_BUTTON_POSITION, WINDOW_CHROME_POSITIONS } from './window-chrome-layout'

function setup(platform: NodeJS.Platform, hasWindow = true) {
  const handlers = new Map<string, (event: { sender: object }, layout: unknown) => void>()
  const ipcMain = { on: (channel: string, handler: never) => handlers.set(channel, handler) }
  const win = { setWindowButtonPosition: vi.fn() }
  const sender = {}
  registerWindowChromeLayout(ipcMain, target => (hasWindow && target === sender ? win : null), platform)

  return { send: (layout: unknown) => handlers.get('hermes:window:chrome-layout')!({ sender }, layout), win }
}

test('default keeps the shipped traffic-light position', () => {
  expect(WINDOW_CHROME_POSITIONS.default).toEqual(WINDOW_BUTTON_POSITION)
  expect(WINDOW_BUTTON_POSITION).toEqual({ x: 12, y: 10 })
})

test('relaxed centres the traffic lights on a 52px row', () => {
  expect(WINDOW_CHROME_POSITIONS.relaxed).toEqual({ x: 20, y: 19 })
})

test.each(['relaxed', 'default'] as const)('%s moves the sender window buttons on macOS', layout => {
  const { send, win } = setup('darwin')

  send(layout)

  expect(win.setWindowButtonPosition).toHaveBeenCalledExactlyOnceWith(WINDOW_CHROME_POSITIONS[layout])
})

test.each([undefined, null, '', 'Relaxed', 'compact', 7, {}, ['relaxed'], '__proto__', 'toString'])(
  'ignores unknown layout %j',
  value => {
    const { send, win } = setup('darwin')

    send(value)

    expect(win.setWindowButtonPosition).not.toHaveBeenCalled()
  }
)

test.each(['win32', 'linux'] as const)('does nothing on %s', platform => {
  const { send, win } = setup(platform)

  send('relaxed')

  expect(win.setWindowButtonPosition).not.toHaveBeenCalled()
})

test('a sender without a window is ignored', () => {
  const { send } = setup('darwin', false)

  expect(() => send('relaxed')).not.toThrow()
})
