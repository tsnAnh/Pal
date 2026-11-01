import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { startFaceVisibility } from './face-visibility'

class FakeObserver {
  static instances: FakeObserver[] = []
  observed = new Set<Element>()
  disconnected = false

  constructor(readonly callback: IntersectionObserverCallback) {
    FakeObserver.instances.push(this)
  }

  observe(target: Element) {
    this.observed.add(target)
  }

  unobserve(target: Element) {
    this.observed.delete(target)
  }

  disconnect() {
    this.observed.clear()
    this.disconnected = true
  }

  report(target: Element, isIntersecting: boolean) {
    this.callback([{ isIntersecting, target } as IntersectionObserverEntry], this as unknown as IntersectionObserver)
  }
}

const face = (name: string) => {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg')

  svg.setAttribute('data-bot-face', name)

  return svg
}

const tick = () => new Promise(resolve => setTimeout(resolve, 0))

describe('startFaceVisibility', () => {
  let stop: () => void

  beforeEach(() => {
    FakeObserver.instances = []
    vi.stubGlobal('IntersectionObserver', FakeObserver)
    document.body.innerHTML = ''
  })

  afterEach(() => {
    stop?.()
    vi.unstubAllGlobals()
  })

  it('uses one observer and marks a face visible only while it intersects', () => {
    const first = face('a')
    const second = face('b')

    document.body.append(first, second)
    stop = startFaceVisibility()

    expect(FakeObserver.instances).toHaveLength(1)

    const [observer] = FakeObserver.instances

    expect([...observer.observed]).toEqual([first, second])
    expect(first.hasAttribute('data-hb-visible')).toBe(false)

    observer.report(first, true)
    expect(first.hasAttribute('data-hb-visible')).toBe(true)
    expect(second.hasAttribute('data-hb-visible')).toBe(false)

    observer.report(first, false)
    expect(first.hasAttribute('data-hb-visible')).toBe(false)
  })

  it('picks up faces added later, nested or direct, and drops removed ones', async () => {
    stop = startFaceVisibility()

    const [observer] = FakeObserver.instances
    const host = document.createElement('div')
    const nested = face('nested')
    const direct = face('direct')

    host.append(nested)
    document.body.append(host, direct)
    await tick()

    expect(observer.observed.has(nested)).toBe(true)
    expect(observer.observed.has(direct)).toBe(true)

    host.remove()
    await tick()

    expect(observer.observed.has(nested)).toBe(false)
    expect(observer.observed.has(direct)).toBe(true)
  })

  it('ignores svgs that are not bot faces', async () => {
    stop = startFaceVisibility()

    const other = document.createElementNS('http://www.w3.org/2000/svg', 'svg')

    document.body.append(other)
    await tick()

    expect(FakeObserver.instances[0].observed.size).toBe(0)
  })

  it('disconnects on stop and is idempotent while running', () => {
    stop = startFaceVisibility()

    expect(startFaceVisibility()).toBe(stop)
    stop()
    expect(FakeObserver.instances[0].disconnected).toBe(true)
  })

  it('does nothing where IntersectionObserver is missing', () => {
    vi.stubGlobal('IntersectionObserver', undefined)
    stop = startFaceVisibility()

    expect(() => stop()).not.toThrow()
  })
})
