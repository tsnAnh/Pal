import { blobatarSilhouette } from '@hermes/plugin-sdk'
import { blobatar } from 'blobatar/blob'
import { describe, expect, it } from 'vitest'

import { eyeFillFor } from './avatar-color'
import { grokifyBlob } from './blob-style'

const SHAPES = [0.11, 0.35, 0.54, 0.65, 0.745, 0.825, 0.8875, 0.9325, 0.965, 0.99]

describe('grokifyBlob', () => {
  it.each(SHAPES)('restyles library output for silhouette %s', shape => {
    const source = blobatar('alpha', { size: 48, traits: { shape } })
    const styled = grokifyBlob(source)
    const doc = new DOMParser().parseFromString(styled, 'image/svg+xml')
    const svg = doc.documentElement

    expect(svg.querySelector('parsererror')).toBeNull()
    expect(svg.getAttribute('viewBox')).toBe('0 0 100 100')

    const figure = svg.firstElementChild!

    expect(figure.getAttribute('transform')).toContain('rotate(-14 50 50)')

    const [body, eyes] = Array.from(figure.children)

    expect(body.getAttribute('stroke-width')).toBe('26')
    expect(body.getAttribute('stroke')).toBe(body.getAttribute('fill'))
    expect(eyes.hasAttribute('data-hb-eyes')).toBe(true)
    expect(eyes.getAttribute('fill')).toBe(eyeFillFor(body.getAttribute('fill')!))

    const gaze = eyes.querySelector(':scope > [data-hb-gaze]')!
    const bounds = gaze.getAttribute('data-hb-bounds')!.split(' ').map(Number)

    expect(bounds).toHaveLength(4)
    expect(bounds[2]).toBeGreaterThan(bounds[0])
    expect(bounds[3]).toBeGreaterThan(bounds[1])

    const wrappers = Array.from(gaze.querySelectorAll(':scope > [data-hb-lids] > [data-hb-eye]'))

    expect(wrappers.map(wrapper => wrapper.getAttribute('data-hb-eye'))).toEqual(['l', 'r'])

    for (const wrapper of wrappers) {
      expect(wrapper.getAttribute('transform')).toMatch(/^translate\([-\d.]+ [-\d.]+\) rotate\(-11\)$/)

      const pill = wrapper.querySelector(':scope > path')!

      expect(wrapper.getAttribute('data-hb-size')).toBe('10 23')
      expect(pill.getAttribute('d')).toMatch(/^M-?[\d.]+ -?[\d.]+L/)
      expect(pill.hasAttribute('transform')).toBe(false)
      expect(wrapper.querySelector('rect')).toBeNull()
    }

    expect(eyes.querySelectorAll('path')).toHaveLength(2)
    expect(gaze.getAttribute('data-hb-mask')).toBeTruthy()
    expect(gaze.getAttribute('data-hb-frame')).toBe(figure.getAttribute('transform'))
    expect(gaze.getAttribute('data-hb-reach')).toBe('13')
  })

  it('returns markup that is not a blob face unchanged', () => {
    for (const input of ['', '<svg viewBox="0 0 40 44"><path d="M0 0"/></svg>', 'not svg']) {
      expect(grokifyBlob(input)).toBe(input)
    }
  })

  it('is idempotent', () => {
    const once = grokifyBlob(blobatar('beta', { size: 32 }))

    expect(once).not.toBe(blobatar('beta', { size: 32 }))
    expect(grokifyBlob(once)).toBe(once)
  })
})

const eyeAreas = (svg: string) =>
  Array.from(parse(svg).querySelectorAll('[data-hb-eye] path'), path => {
    const points = Array.from((path.getAttribute('d') ?? '').matchAll(/(-?[\d.]+) (-?[\d.]+)/g), m => [
      Number(m[1]),
      Number(m[2])
    ])

    return (
      Math.abs(
        points.reduce(
          (sum, [x, y], i) => sum + x * points[(i + 1) % points.length][1] - points[(i + 1) % points.length][0] * y,
          0
        )
      ) / 2
    )
  })

describe('grokifyBlob eyes', () => {
  const flatPill = 10 * 23 - (4 - Math.PI) * 5 ** 2

  it('paints the eyes on a round body, foreshortened where it curves away', () => {
    const round = grokifyBlob(blobatar('alpha', { size: 48, traits: { shape: 0.11 } }), { circle: true })
    const areas = eyeAreas(round)

    expect(areas).toHaveLength(2)

    for (const area of areas) {
      expect(area).toBeGreaterThan(flatPill * 0.5)
      expect(area).toBeLessThan(flatPill * 0.995)
    }
  })

  it.each(SHAPES)('keeps both eyes on the body for silhouette %s', shape => {
    const areas = eyeAreas(grokifyBlob(blobatar('alpha', { size: 48, traits: { shape } })))

    expect(areas).toHaveLength(2)
    expect(areas.every(area => area > flatPill * 0.4 && area <= flatPill * 1.001)).toBe(true)
  })
})

describe('grokifyBlob attribute safety', () => {
  const hostile = (fill: string) =>
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><g fill="${fill}"><circle cx="50" cy="50" r="30"/></g><g fill="#f3f4fd"><path d="M10 10C20 20 30 30 40 40"/><path d="M50 10C60 20 70 30 80 40"/></g></svg>`

  it('escapes the body fill it writes into attributes', () => {
    const styled = grokifyBlob(hostile('red<image href=x onerror=alert(1)>'))
    const doc = new DOMParser().parseFromString(styled, 'image/svg+xml')

    expect(doc.querySelector('parsererror')).toBeNull()
    expect(doc.querySelector('image')).toBeNull()
    expect(styled).not.toContain('<image')
  })

  it('lights the eyes on a dark body and darkens them on a light one', () => {
    const eyeFill = (svg: string) =>
      new DOMParser()
        .parseFromString(grokifyBlob(svg), 'image/svg+xml')
        .querySelector('[data-hb-eyes]')
        ?.getAttribute('fill')

    expect(eyeFill(hostile('#1a1a2a'))).toBe('#f3f4fd')
    expect(eyeFill(hostile('#fde68a'))).toBe('#1b1b1b')
  })
})

const KINDS = ['round', 'organic', 'boxy', 'capsule', 'nub', 'cloud', 'droplet', 'hexagon', 'sun', 'triangle']

const NAMES = [
  'alpha',
  'beta',
  'gamma',
  'delta',
  'epsilon',
  'zeta',
  'eta',
  'theta',
  'iota',
  'kappa',
  'lambda',
  'mu',
  'nu',
  'xi',
  'omicron',
  'pi',
  'rho',
  'sigma',
  'tau',
  'upsilon',
  'phi',
  'chi',
  'psi',
  'omega'
]

const bodyPath = (svg: string) => /<g fill="[^"]+"><path d="([^"]+)"/.exec(svg)![1]

function parse(svg: string) {
  return new DOMParser().parseFromString(svg, 'image/svg+xml').documentElement
}

describe('grokifyBlob circle', () => {
  const roundNames = NAMES.filter(name => blobatarSilhouette(name) === 'round')

  it('has round faces to test', () => {
    expect(roundNames.length).toBeGreaterThanOrEqual(2)
  })

  it.each(['alpha', 'beta', 'gamma', 'delta', 'kappa', 'sigma'])('draws %s as an exact circle when round', name => {
    const source = blobatar(name, { size: 48, traits: { shape: 0.11 } })
    const svg = parse(grokifyBlob(source, { circle: true }))
    const body = svg.querySelector('g > g')!
    const circles = body.querySelectorAll('circle')

    expect(body.querySelector('path')).toBeNull()
    expect(circles).toHaveLength(1)
    expect(body.getAttribute('stroke-width')).toBe('26')
    expect(body.getAttribute('stroke-linejoin')).toBe('round')

    const [cx, cy, r] = ['cx', 'cy', 'r'].map(attr => Number(circles[0].getAttribute(attr)))

    const points = [...bodyPath(source).matchAll(/(-?\d+(?:\.\d+)?) (-?\d+(?:\.\d+)?)/g)].map(m => [
      Number(m[1]),
      Number(m[2])
    ])

    const xs = points.map(([x]) => x)
    const ys = points.map(([, y]) => y)

    expect(cx).toBeCloseTo((Math.min(...xs) + Math.max(...xs)) / 2, 1)
    expect(cy).toBeCloseTo((Math.min(...ys) + Math.max(...ys)) / 2, 1)
    expect(r).toBeCloseTo((Math.max(...xs) - Math.min(...xs) + Math.max(...ys) - Math.min(...ys)) / 4, 1)

    const radii = Array.from({ length: 72 }, (_, i) => {
      const a = (i / 72) * Math.PI * 2

      return Math.hypot(cx + r * Math.cos(a) - cx, cy + r * Math.sin(a) - cy)
    })

    expect(Math.max(...radii) - Math.min(...radii)).toBeLessThan(1e-9)

    const bounds = svg.querySelector('[data-hb-bounds]')!.getAttribute('data-hb-bounds')!.split(' ').map(Number)

    expect(bounds[0]).toBeLessThan(cx)
    expect(bounds[2]).toBeGreaterThan(cx)
    expect(bounds[1]).toBeLessThan(cy)
    expect(bounds[3]).toBeGreaterThan(cy)
  })

  it('leaves every other silhouette untouched', () => {
    for (const shape of SHAPES.slice(1)) {
      const source = blobatar('alpha', { size: 48, traits: { shape } })

      expect(grokifyBlob(source, { circle: false })).toBe(grokifyBlob(source))
      expect(grokifyBlob(source)).toContain('<path')
    }
  })

  it('is idempotent', () => {
    const once = grokifyBlob(blobatar('beta', { size: 32, traits: { shape: 0.11 } }), { circle: true })

    expect(grokifyBlob(once, { circle: true })).toBe(once)
  })
})

describe('blobatarSilhouette', () => {
  it.each(NAMES)('matches the silhouette blobatar renders for %s', name => {
    const kind = blobatarSilhouette(name)

    expect(KINDS).toContain(kind)

    const natural = bodyPath(blobatar(name, { size: 48 }))
    const pinned = bodyPath(blobatar(name, { size: 48, traits: { shape: SHAPES[KINDS.indexOf(kind)] } }))

    expect(pinned).toBe(natural)
  })

  it('honours explicit overrides', () => {
    expect(blobatarSilhouette('alpha', { shape: 0.99 })).toBe('triangle')
    expect(blobatarSilhouette('alpha', { shape: 0.11 })).toBe('round')
  })
})

describe('avatar swatches', () => {
  it('are eighteen distinct colours the avatar accepts', async () => {
    const { AVATAR_SWATCHES } = await import('./avatar-swatches')
    const { safeAvatarColor } = await import('./avatar-color')

    expect(AVATAR_SWATCHES).toHaveLength(18)
    expect(new Set(AVATAR_SWATCHES).size).toBe(18)
    expect(AVATAR_SWATCHES.every(hex => safeAvatarColor(hex) === hex)).toBe(true)
  })

  it('give a charcoal body light eyes and a white body dark eyes', () => {
    expect(eyeFillFor('#3a3a3a')).toBe('#f3f4fd')
    expect(eyeFillFor('#f5f5f5')).toBe('#1b1b1b')
  })
})
