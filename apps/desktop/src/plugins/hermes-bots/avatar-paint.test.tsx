import { cleanup, render } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('@hermes/plugin-sdk', async () => {
  const { atom } = await import('nanostores')
  const { blobatar } = await import('blobatar/blob')

  return {
    atom,
    avatarLoadingClips: (await import('./loading-clips-test-utils')).loadingClipFile(),
    blobatarSvg: blobatar,
    createBudgetedLoop: undefined,
    host: { state: { connectionId: { get: () => 'local' } } },
    profileColor: () => '#8b5cf6',
    PROFILE_SWATCHES: [],
    queryClient: undefined,
    useQuery: vi.fn(),
    useValue: vi.fn()
  }
})

vi.mock('./shared', () => ({ getPluginCtx: () => null, ID: 'hermes-bots' }))

import { BotFace, stopFaceClock } from './avatar'
import { paintMotion } from './avatar-paint'

const EPOCH = 1_800_000_000_000

const FACES = {
  blob: { color: '#3e8ef7', name: 'alpha', shape: 'blobatar:alpha:triangle' },
  math: { color: '#3e8ef7', name: 'alpha', shape: 'squircle' },
  sigil: { color: '#3e8ef7', name: 'alpha', shape: 'sigil-3' }
} as const

type Kind = keyof typeof FACES

function mount(kind: Kind, mood: 'idle' | 'think' | 'work' = 'idle') {
  const view = render(<BotFace {...FACES[kind]} mood={mood} size={48} />)
  const svg = view.container.querySelector('svg') as SVGSVGElement

  const eyes = () => Array.from(svg.querySelectorAll<SVGGElement>('[data-hb-eye]'))

  return {
    dots: () => Array.from(svg.querySelectorAll('[data-hb-dot]'), dot => dot.getAttribute('opacity')),
    eyes,
    paths: () => eyes().map(eye => eye.querySelector('path')!.getAttribute('d')),
    rerender: (next: 'idle' | 'think' | 'work') => view.rerender(<BotFace {...FACES[kind]} mood={next} size={48} />),
    svg,
    transforms: () => eyes().map(eye => eye.getAttribute('transform'))
  }
}

const paint = (svg: SVGSVGElement, now: number, reduceMotion = false) => paintMotion(svg, now, EPOCH, reduceMotion)

beforeEach(() => {
  window.requestAnimationFrame = () => 0
  window.cancelAnimationFrame = () => undefined
})

afterEach(() => {
  cleanup()
  stopFaceClock()
})

describe.each(Object.keys(FACES) as Kind[])('the %s face while loading', kind => {
  it('plays loading poses that differ from rest and move the body', () => {
    const face = mount(kind, 'work')
    const rest = face.paths()
    const restTransforms = face.transforms()
    const seen = new Set<string>()
    let bodyMoved = false

    expect(paint(face.svg, 0)).toBe(true)

    for (let now = 0; now <= 12_000; now += 40) {
      expect(paint(face.svg, now)).toBe(true)
      seen.add(face.paths().join('|'))

      if (
        face.svg.style.transform &&
        !/translate\(0\.0000%, 0\.0000%\) rotate\(0\.0000deg\) scale\(1\.00000, 1\.00000\)/.test(
          face.svg.style.transform
        )
      ) {
        bodyMoved = true
      }
    }

    expect(seen.size).toBeGreaterThan(50)
    expect(seen.has(rest.join('|'))).toBe(true)
    expect([...seen].some(shape => shape !== rest.join('|'))).toBe(true)
    expect(face.transforms()).not.toEqual(restTransforms)
    expect(bodyMoved).toBe(true)
    expect(face.svg.hasAttribute('data-hb-motion')).toBe(true)
  })

  it('keeps every painted eye a closed outline or hides it', () => {
    const face = mount(kind, 'think')

    for (let now = 0; now <= 20_000; now += 50) {
      paint(face.svg, now)

      for (const d of face.paths()) {
        expect(d).toMatch(/^(M-?[\d.]+ -?[\d.]+(L-?[\d.]+ -?[\d.]+)+Z)*$/)
        expect(d).not.toContain('NaN')
      }
    }
  })

  it('settles over 0.4 seconds back to exactly the static render on idle', () => {
    const face = mount(kind, 'work')
    const staticPaths = face.paths()
    const staticTransforms = face.transforms()

    for (let now = 0; now <= 5000; now += 50) {
      paint(face.svg, now)
    }

    face.rerender('idle')
    expect(face.svg.getAttribute('data-hb-mood')).toBe('idle')
    expect(paint(face.svg, 5100)).toBe(true)
    expect(face.paths()).not.toEqual(staticPaths)

    expect(paint(face.svg, 5300)).toBe(true)
    expect(paint(face.svg, 5500)).toBe(false)

    expect(face.paths()).toEqual(staticPaths)
    expect(face.transforms()).toEqual(staticTransforms)
    expect(face.svg.style.transform).toBe('')
    expect(face.svg.style.transformOrigin).toBe('')
    expect(face.svg.style.opacity).toBe('')
    expect(face.svg.hasAttribute('data-hb-motion')).toBe(false)
    expect(paint(face.svg, 5600)).toBe(false)
  })

  it('pulses instead of moving under reduced motion', () => {
    const face = mount(kind, 'work')
    const staticPaths = face.paths()

    paint(face.svg, 0, true)
    expect(paint(face.svg, 1000, true)).toBe(true)

    expect(Number(face.svg.style.opacity)).toBeCloseTo(0.6, 4)
    expect(face.paths()).toEqual(staticPaths)
    expect(paint(face.svg, 2000, true)).toBe(true)
    expect(face.svg.style.opacity).toBe('')
  })

  it('leaves an idle face alone', () => {
    const face = mount(kind, 'idle')
    const before = face.svg.outerHTML

    expect(paint(face.svg, 100)).toBe(false)
    expect(paint(face.svg, 5000)).toBe(false)
    expect(face.svg.outerHTML).toBe(before)
  })

  it('starts a different clip order for each loading session', () => {
    const openers = new Set<string>()

    for (let session = 0; session < 8; session++) {
      const face = mount(kind, 'work')

      paintMotion(face.svg, 0, EPOCH + session * 977, false)

      for (let now = 400; now <= 1400; now += 100) {
        paintMotion(face.svg, now, EPOCH + session * 977, false)
      }

      openers.add(face.paths().join('|') + face.svg.style.transform)
      cleanup()
    }

    expect(openers.size).toBeGreaterThan(2)
  })
})

describe('the loading dots of the math face', () => {
  it('follow the working rhythm and go dark again on idle', () => {
    const face = mount('math', 'work')

    paint(face.svg, 0)
    paint(face.svg, 1300)

    const lit = face.dots().map(Number)

    expect(Math.max(...lit)).toBeGreaterThan(0.2)
    expect(lit).not.toEqual([0, 0, 0])

    face.rerender('idle')
    paint(face.svg, 1400)
    paint(face.svg, 1900)
    expect(face.dots()).toEqual(['0', '0', '0'])
  })
})

describe('a face whose mood changes in place', () => {
  it('keeps one element for a blob, so the settle can blend', () => {
    const face = mount('blob', 'idle')
    const element = face.svg

    expect(face.svg.getAttribute('data-hb-mood')).toBe('idle')
    face.rerender('work')
    expect(face.svg.parentElement?.firstElementChild).toBe(element)
    expect(element.getAttribute('data-hb-mood')).toBe('work')
  })

  it('blends from the idle pose into the clips rather than snapping', () => {
    const face = mount('math', 'idle')
    const staticPaths = face.paths()

    expect(paint(face.svg, 0)).toBe(false)
    face.rerender('work')
    expect(paint(face.svg, 100)).toBe(true)
    expect(face.paths()).toEqual(staticPaths)
    paint(face.svg, 300)
    expect(face.paths()).not.toEqual(staticPaths)
  })

  it('starts a fresh session when working turns into thinking', () => {
    const face = mount('sigil', 'work')

    paint(face.svg, 0)
    paint(face.svg, 3000)
    face.rerender('think')
    expect(paint(face.svg, 3010)).toBe(true)
    expect(face.svg.getAttribute('data-hb-mood')).toBe('think')
  })
})
