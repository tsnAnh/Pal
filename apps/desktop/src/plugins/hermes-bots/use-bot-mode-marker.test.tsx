import { cleanup, render } from '@testing-library/react'
import { useRef } from 'react'
import { afterEach, beforeAll, expect, it } from 'vitest'

import { useBotModeMarker } from './use-bot-mode-marker'

function Pane() {
  const ref = useRef<HTMLDivElement>(null)

  useBotModeMarker(ref)

  return <div ref={ref} />
}

beforeAll(() => {
  globalThis.ResizeObserver = class {
    disconnect() {}
    observe() {}
    unobserve() {}
  } as unknown as typeof ResizeObserver

  Element.prototype.getClientRects = function () {
    return [{}] as unknown as DOMRectList
  }
})

afterEach(() => {
  cleanup()
  delete window.document.documentElement.dataset.botMode
})

it('keeps the root marker until the last consumer unmounts', () => {
  const first = render(<Pane />)
  const second = render(<Pane />)

  expect('botMode' in window.document.documentElement.dataset).toBe(true)

  first.unmount()
  expect('botMode' in window.document.documentElement.dataset).toBe(true)

  second.unmount()
  expect('botMode' in window.document.documentElement.dataset).toBe(false)
})
