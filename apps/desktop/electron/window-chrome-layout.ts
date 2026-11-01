const TITLEBAR_HEIGHT = 34
const RELAXED_TITLEBAR_HEIGHT = 52
const MACOS_TRAFFIC_LIGHTS_HEIGHT = 14

export interface WindowButtonPosition {
  x: number
  y: number
}

export const WINDOW_BUTTON_POSITION: WindowButtonPosition = {
  x: 24,
  y: TITLEBAR_HEIGHT / 2 - MACOS_TRAFFIC_LIGHTS_HEIGHT / 2
}

export const WINDOW_CHROME_POSITIONS = {
  default: WINDOW_BUTTON_POSITION,
  relaxed: { x: 20, y: (RELAXED_TITLEBAR_HEIGHT - MACOS_TRAFFIC_LIGHTS_HEIGHT) / 2 }
} as const satisfies Record<string, WindowButtonPosition>

export type WindowChromeLayout = keyof typeof WINDOW_CHROME_POSITIONS

const CHANNEL = 'hermes:window:chrome-layout'

function isChromeLayout(value: unknown): value is WindowChromeLayout {
  return typeof value === 'string' && Object.hasOwn(WINDOW_CHROME_POSITIONS, value)
}

interface ButtonWindow {
  setWindowButtonPosition?: (position: WindowButtonPosition) => void
}

export function registerWindowChromeLayout<Sender>(
  ipcMain: { on: (channel: string, handler: (event: { sender: Sender }, layout: unknown) => void) => unknown },
  windowFor: (sender: Sender) => ButtonWindow | null | undefined,
  platform: NodeJS.Platform
): void {
  ipcMain.on(CHANNEL, (event, layout) => {
    if (platform !== 'darwin' || !isChromeLayout(layout)) {
      return
    }

    windowFor(event.sender)?.setWindowButtonPosition?.(WINDOW_CHROME_POSITIONS[layout])
  })
}
