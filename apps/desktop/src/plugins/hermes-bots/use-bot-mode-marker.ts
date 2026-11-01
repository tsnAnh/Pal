import { type RefObject, useEffect } from 'react'

const MARKER = 'botMode'

let holders = 0

function acquire() {
  if (holders++ === 0) {
    document.documentElement.dataset[MARKER] = ''
  }
}

function release() {
  if (--holders === 0) {
    delete document.documentElement.dataset[MARKER]
  }
}

export function useBotModeMarker(paneRef: RefObject<HTMLElement | null>) {
  useEffect(() => {
    const pane = paneRef.current

    if (!pane) {
      return
    }

    let held = false

    const sync = () => {
      const visible = pane.getClientRects().length > 0

      if (visible && !held) {
        acquire()
        held = true
      } else if (!visible && held) {
        release()
        held = false
      }
    }

    const observer = new ResizeObserver(sync)

    observer.observe(pane)
    sync()

    return () => {
      observer.disconnect()

      if (held) {
        release()
      }
    }
  }, [paneRef])
}
