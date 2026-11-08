/**
 * The shared face clock: ONE animation loop for every mounted math face.
 *
 * A large roster mounts hundreds of faces, so the clock must not burn frames
 * (or 1Hz whole-document shadow walks) on faces nobody can see. It therefore
 * parks itself whenever there is nothing worth animating — no faces mounted,
 * or none intersecting — and is woken by exactly two events: a `BotFace`
 * render re-entering `startFaceClock`, and a face scrolling into view.
 *
 * Newer desktops delegate scheduling to the SDK's `createBudgetedLoop`
 * (15fps budget, hidden/minimized pause, dormancy, teardown); older shells
 * fall back to the hand-rolled rAF path. Both are exercised here, because the
 * fallback is what every un-upgraded install runs.
 */

import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { budgetedLoopMock } = vi.hoisted(() => ({ budgetedLoopMock: { impl: undefined as unknown } }))

vi.mock('@hermes/plugin-sdk', async () => {
  const { atom } = await import('nanostores')

  return {
    atom,
    avatarLoadingClips: (await import('./loading-clips-test-utils')).loadingClipFile(),
    blobatarSvg: undefined,
    // A live binding on the real SDK; the getter lets one test file cover both
    // the budgeted-loop path and the older hand-rolled one.
    get createBudgetedLoop() {
      return budgetedLoopMock.impl
    },
    host: { state: { connectionId: { get: () => 'local' } } },
    profileColor: () => '#8b5cf6',
    PROFILE_SWATCHES: [],
    queryClient: undefined,
    useQuery: vi.fn(),
    useValue: vi.fn()
  }
})

vi.mock('./shared', () => ({ getPluginCtx: () => null, ID: 'hermes-bots' }))

interface ObserverEntry {
  isIntersecting: boolean
  target: Element
}

/** The live fake observer, so a test can drive visibility changes. */
let observer: FakeIntersectionObserver | null = null

class FakeIntersectionObserver {
  callback: (entries: ObserverEntry[]) => void
  disconnected = false
  observed = new Set<Element>()

  constructor(callback: (entries: ObserverEntry[]) => void) {
    this.callback = callback
    observer = this
  }

  disconnect() {
    this.disconnected = true
    this.observed.clear()
  }

  emit(entries: ObserverEntry[]) {
    this.callback(entries)
  }

  observe(element: Element) {
    this.observed.add(element)
  }

  unobserve(element: Element) {
    this.observed.delete(element)
  }
}

let frames = new Map<number, (now: number) => void>()
let frameSeq = 0
let now = 0

/** Run every frame scheduled so far and advance the clock. */
function pump(advance = 100) {
  now += advance

  const pending = [...frames.values()]

  frames.clear()

  for (const frame of pending) {
    frame(now)
  }
}

function mountFace() {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg')

  svg.setAttribute('data-hb-math', '1')
  document.body.append(svg)

  return svg
}

async function loadClock() {
  vi.resetModules()

  return import('./avatar')
}

beforeEach(() => {
  frames = new Map()
  frameSeq = 0
  now = 0
  observer = null
  budgetedLoopMock.impl = undefined
  document.body.innerHTML = ''
  delete window.__hbFaceClock
  vi.stubGlobal('IntersectionObserver', FakeIntersectionObserver)

  window.requestAnimationFrame = (callback: FrameRequestCallback) => {
    frameSeq += 1
    frames.set(frameSeq, callback)

    return frameSeq
  }

  window.cancelAnimationFrame = (id: number) => {
    frames.delete(id)
  }
})

afterEach(() => {
  window.__hbFaceClock?.stop()
  vi.unstubAllGlobals()
})

describe('the hand-rolled rAF path (older shells)', () => {
  it('parks itself when no faces are mounted', async () => {
    const { startFaceClock } = await loadClock()

    startFaceClock()
    expect(frames.size).toBe(1)

    pump()
    expect(frames.size).toBe(0)
  })

  it('wakes a parked clock when a face mounts', async () => {
    const { startFaceClock } = await loadClock()

    startFaceClock()
    pump()
    expect(frames.size).toBe(0)

    mountFace()
    // The BotFace render path — re-entry is the wake signal.
    startFaceClock()
    expect(frames.size).toBe(1)
  })

  it('parks when every face scrolls out and the observer wakes it back', async () => {
    const { startFaceClock } = await loadClock()
    const face = mountFace()

    startFaceClock()
    pump()
    // Observed but not yet intersecting: nothing visible, so park.
    expect(frames.size).toBe(0)

    observer!.emit([{ isIntersecting: true, target: face }])
    expect(frames.size).toBe(1)

    pump()
    expect(frames.size).toBe(1)

    observer!.emit([{ isIntersecting: false, target: face }])
    pump()
    pump()
    expect(frames.size).toBe(0)
  })

  it('stops cleanly and can be restarted', async () => {
    const { startFaceClock, stopFaceClock } = await loadClock()
    const face = mountFace()

    startFaceClock()
    observer!.emit([{ isIntersecting: true, target: face }])
    pump()
    expect(frames.size).toBe(1)

    const first = observer!

    stopFaceClock()
    expect(frames.size).toBe(0)
    expect(first.disconnected).toBe(true)
    expect(window.__hbFaceClock).toBeUndefined()

    // A fresh start after teardown re-initializes rather than hitting a dead
    // handle left on `window`.
    startFaceClock()
    expect(frames.size).toBe(1)
  })

  it('stops the whole-document walk when a face unmounts', async () => {
    const { startFaceClock } = await loadClock()
    const face = mountFace()

    startFaceClock()
    observer!.emit([{ isIntersecting: true, target: face }])
    pump()

    face.remove()
    // The 1Hz rescan drops the node from both caches and parks the clock.
    pump(1500)
    pump()

    expect(observer!.observed.has(face)).toBe(false)
    expect(frames.size).toBe(0)
  })
})

describe('the SDK budgeted-loop path', () => {
  interface CapturedLoop {
    draw: (now: number) => void
    idleWhen: () => boolean
  }

  function captureLoop() {
    const captured: Partial<CapturedLoop> = {}
    const calls = { created: 0, dispose: 0, fps: 0, wake: 0 }

    budgetedLoopMock.impl = (draw: (now: number) => void, options: { fps: number; idleWhen: () => boolean }) => {
      calls.created += 1
      calls.fps = options.fps
      captured.draw = draw
      captured.idleWhen = options.idleWhen

      return {
        dispose: () => {
          calls.dispose += 1
        },
        isDormant: () => false,
        wake: () => {
          calls.wake += 1
        }
      }
    }

    return { calls, captured }
  }

  it('reports idleness from visible-face state and wakes on visibility', async () => {
    const { calls, captured } = captureLoop()
    const { startFaceClock } = await loadClock()
    const face = mountFace()

    startFaceClock()

    // The first draw performs the initial scan + observation.
    captured.draw!(1000)
    expect(captured.idleWhen!()).toBe(true)

    observer!.emit([{ isIntersecting: true, target: face }])
    expect(captured.idleWhen!()).toBe(false)
    expect(calls.wake).toBeGreaterThanOrEqual(1)

    // Re-entry (a BotFace mount) wakes rather than re-initializing.
    startFaceClock()
    expect(calls.wake).toBeGreaterThanOrEqual(2)
  })

  it('keeps a single clock across plugin loads', async () => {
    // Parked on `window` so a second load adopts the running clock instead of
    // starting a rival loop.
    const { calls } = captureLoop()
    const first = await loadClock()

    mountFace()
    first.startFaceClock()

    const second = await loadClock()

    second.startFaceClock()

    expect(calls.created).toBe(1)
    expect(calls.wake).toBeGreaterThanOrEqual(1)
  })
})

describe('the painted pill eyes', () => {
  async function paintedFace() {
    const { BotFace, startFaceClock } = await loadClock()
    const host = document.createElement('div')

    host.innerHTML = renderToStaticMarkup(
      createElement(BotFace, { color: '#3e8ef7', mood: 'work', name: 'alpha', shape: 'circle', size: 48 })
    )
    document.body.append(host)

    const face = host.querySelector('svg')!

    startFaceClock()
    observer!.emit([{ isIntersecting: true, target: face }])

    return {
      eyes: Array.from(face.querySelectorAll<SVGGElement>('[data-hb-eye]')),
      gaze: face.querySelector('[data-hb-gaze]')!,
      lids: face.querySelector('[data-hb-lids]')!,
      staticShapes: Array.from(face.querySelectorAll('[data-hb-eye] path'), path => path.getAttribute('d'))
    }
  }

  it('plays the loading clips on the eyes and leaves the gaze group where it is', async () => {
    const { eyes, gaze } = await paintedFace()

    pump(100)

    expect(gaze.hasAttribute('transform')).toBe(false)

    for (const eye of eyes) {
      expect(eye.getAttribute('transform')).toMatch(/^matrix\(/)
    }
  })

  it('repaints the eyes on the body wherever the clips carry them', async () => {
    const { eyes, staticShapes } = await paintedFace()
    const shapes = new Set<string>()

    for (let i = 0; i < 45; i++) {
      pump(100)
      eyes.forEach(eye => shapes.add(eye.querySelector('path')!.getAttribute('d')!))
    }

    expect(shapes.size, 'a carried eye is re-projected, not left as the static drawing').toBeGreaterThan(
      staticShapes.length
    )

    for (const shape of shapes) {
      expect(shape).toMatch(/^(M-?[\d.]+ -?[\d.]+L.*Z)?$/)
    }
  })

  it('leaves the blink to the CSS however long the clock runs', async () => {
    const { lids } = await paintedFace()

    for (let i = 0; i < 45; i++) {
      pump(100)
    }

    expect(lids.hasAttribute('transform')).toBe(false)
    expect(lids.getAttribute('style')).toBeNull()
  })
})
