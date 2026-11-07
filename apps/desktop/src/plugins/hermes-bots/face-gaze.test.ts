import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import {
  ATTENTION_GAP,
  composeEyes,
  type EyePose,
  type EyeRig,
  FIGURE_TILT_DEGREES,
  GAZE_REACH,
  gazeOffset,
  startFaceGaze
} from './face-gaze'

const rig: EyeRig = {
  bounds: { maxX: 90, maxY: 90, minX: 10, minY: 10 },
  left: { height: 21, slant: -11, width: 9, x: 55, y: 42 },
  right: { height: 21, slant: -11, width: 9, x: 74, y: 42 }
}

const origin = { x: 120, y: 120 }
const faceWidth = 40
const noGaze = { x: 0, y: 0 }
const mid = (eyes: ReturnType<typeof composeEyes>) => (eyes[0].x + eyes[1].x) / 2

const extent = ({ angle, surface }: Pick<EyePose, 'angle' | 'surface'>, width = 9, height = 21) => {
  const radians = (angle * Math.PI) / 180
  const cos = Math.cos(radians)
  const sin = Math.sin(radians)
  const [a, b, c, d] = surface
  const shape = [cos * a - sin * b, sin * a + cos * b, cos * c - sin * d, sin * c + cos * d]

  return {
    x: (Math.abs(shape[0]) * width + Math.abs(shape[2]) * height) / 2,
    y: (Math.abs(shape[1]) * width + Math.abs(shape[3]) * height) / 2
  }
}

describe('gazeOffset', () => {
  it('saturates at the unit disc when the pointer is far to the right', () => {
    const offset = gazeOffset(origin, faceWidth, { x: 5000, y: 120 })

    expect(offset.x).toBeCloseTo(1)
    expect(offset.y).toBeCloseTo(0)
  })

  it('looks the opposite way for a pointer left of and above the origin', () => {
    const offset = gazeOffset(origin, faceWidth, { x: 0, y: 0 })

    expect(offset.x).toBeLessThan(0)
    expect(offset.y).toBeLessThan(0)
  })

  it('stays centred on the origin', () => {
    expect(gazeOffset(origin, faceWidth, origin)).toEqual({ x: 0, y: 0 })
  })

  it('reaches full travel with the pointer on the face edge', () => {
    expect(gazeOffset(origin, faceWidth, { x: origin.x + faceWidth / 2, y: origin.y }).x).toBeCloseTo(1)
    expect(gazeOffset(origin, faceWidth, { x: origin.x + faceWidth / 4, y: origin.y }).x).toBeCloseTo(0.5)
  })
})

describe('composeEyes', () => {
  it('holds the baked idle pose at zero attention whatever the gaze', () => {
    const eyes = composeEyes(rig, 0, { x: 1, y: -1 })

    expect(eyes[0]).toEqual({ angle: -11, surface: [1, 0, 0, 1], x: 55, y: 42 })
    expect(eyes[1]).toEqual({ angle: -11, surface: [1, 0, 0, 1], x: 74, y: 42 })
  })

  const pairSpan = (eyes: { x: number; y: number }[]) => Math.hypot(eyes[1].x - eyes[0].x, eyes[1].y - eyes[0].y)

  const screenSlope = (eyes: { x: number; y: number }[]) => {
    const tilt = (-FIGURE_TILT_DEGREES * Math.PI) / 180
    const dx = eyes[1].x - eyes[0].x
    const dy = eyes[1].y - eyes[0].y

    return dx * Math.sin(tilt) + dy * Math.cos(tilt)
  }

  it('stands the eyes upright on screen, wider apart and re-centred at full attention', () => {
    const eyes = composeEyes(rig, 1, noGaze)

    expect(eyes[0].angle).toBeCloseTo(FIGURE_TILT_DEGREES)
    expect(eyes[1].angle).toBeCloseTo(FIGURE_TILT_DEGREES)
    expect(pairSpan(eyes)).toBeCloseTo(19 * ATTENTION_GAP)
    expect(screenSlope(eyes)).toBeCloseTo(0)
    expect(mid(eyes)).toBeCloseTo(50)
    expect(eyes[0].surface).toEqual([1, 0, 0, 1])
  })

  it('turns the eyes around a ball when looking sideways', () => {
    const level = pairSpan(composeEyes(rig, 1, noGaze))
    const right = composeEyes(rig, 1, { x: 1, y: 0 })
    const left = composeEyes(rig, 1, { x: -1, y: 0 })

    expect(right[1].surface[0]).toBeLessThan(0.8)
    expect(right[0].surface[0]).toBeGreaterThan(1)
    expect(left[0].surface[0]).toBeCloseTo(right[1].surface[0])
    expect(left[1].surface[0]).toBeCloseTo(right[0].surface[0])
    expect(pairSpan(right)).toBeLessThan(level * 0.9)
    expect(screenSlope(right)).toBeCloseTo(0)
  })

  it('squashes both eyes vertically when looking up or down', () => {
    for (const y of [-1, 1]) {
      const eyes = composeEyes(rig, 1, { x: 0, y })

      for (const eye of eyes) {
        expect(eye.surface[3]).toBeLessThan(0.95)
      }

      expect(eyes[0].surface[1]).toBeCloseTo(-eyes[1].surface[1])
    }
  })

  it('scales the gaze travel with attention', () => {
    const travel = (attention: number) => {
      const looking = composeEyes(rig, attention, { x: 1, y: 0 })
      const level = composeEyes(rig, attention, noGaze)

      return Math.hypot(mid(looking) - mid(level), (looking[0].y + looking[1].y - level[0].y - level[1].y) / 2)
    }

    const full = travel(1)

    expect(full).toBeGreaterThan(GAZE_REACH.x * 80 * 0.8)
    expect(full).toBeLessThanOrEqual(GAZE_REACH.x * 80 + 1e-6)
    expect(travel(0.5)).toBeGreaterThan(full * 0.4)
    expect(travel(0.5)).toBeLessThan(full * 0.6)
    expect(travel(0)).toBeCloseTo(0)
  })

  it('keeps every eye inside the body box at the widest look', () => {
    for (const gaze of [
      { x: 1, y: 0 },
      { x: -1, y: 0 },
      { x: 0, y: 1 },
      { x: 0, y: -1 },
      { x: 0.7, y: 0.7 }
    ]) {
      for (const eye of composeEyes(rig, 1, gaze)) {
        const { x: hx, y: hy } = extent(eye)

        expect(eye.x - hx).toBeGreaterThanOrEqual(10 - 1e-6)
        expect(eye.x + hx).toBeLessThanOrEqual(90 + 1e-6)
        expect(eye.y - hy).toBeGreaterThanOrEqual(10 - 1e-6)
        expect(eye.y + hy).toBeLessThanOrEqual(90 + 1e-6)
      }
    }
  })

  it('clamps a narrow body without separating or merging the pair', () => {
    const narrow: EyeRig = { ...rig, bounds: { maxX: 80, maxY: 90, minX: 40, minY: 10 } }
    const eyes = composeEyes(narrow, 1, { x: 1, y: 0 })

    expect(pairSpan(eyes)).toBeGreaterThan(19 * ATTENTION_GAP * 0.7)
    expect(pairSpan(eyes)).toBeLessThan(19 * ATTENTION_GAP)
    expect(screenSlope(eyes)).toBeCloseTo(0)
    expect(eyes[1].x + extent(eyes[1]).x).toBeLessThanOrEqual(80 + 1e-6)
  })
})

describe('startFaceGaze', () => {
  let stop: () => void
  let reduced = false
  let queue: FrameRequestCallback[] = []
  let clock = 0

  const REST_LEFT = 'translate(55 42) rotate(-11)'
  const REST_RIGHT = 'translate(74 42) rotate(-11)'

  const mount = (kind: 'blob' | 'math' = 'blob', gazeTransform = '') => {
    const attrs = kind === 'math' ? 'data-hb-math="1"' : 'data-bot-gaze="eyes"'

    const eye = (side: string, transform: string) =>
      `<g data-hb-eye="${side}" data-hb-rest="${transform}" transform="${transform}"><rect x="-4.5" y="-10.5" width="9" height="21" rx="4.5"/></g>`

    document.body.innerHTML = `
      <div data-bot-gaze-scope id="scope">
        <svg data-bot-face="a" ${attrs} viewBox="0 0 100 100"><g><g data-hb-gaze="" data-hb-bounds="10 10 90 90" ${gazeTransform ? `transform="${gazeTransform}"` : ''}>
          ${eye('l', REST_LEFT)}${eye('r', REST_RIGHT)}
        </g></g></svg>
      </div>
      <div id="outside"></div>`
    const face = document.querySelector('svg')!
    face.getBoundingClientRect = () => ({ left: 100, top: 100, width: 40, height: 40 }) as DOMRect
    const [left, right] = Array.from(document.querySelectorAll<SVGGElement>('[data-hb-eye]'))

    return { left, right, scope: document.getElementById('scope')!, outside: document.getElementById('outside')! }
  }

  const frames = (count: number) => {
    for (let i = 0; i < count; i++) {
      const callbacks = queue
      queue = []
      clock += 1000 / 60
      callbacks.forEach(cb => cb(clock))
    }
  }

  const parse = (eye: Element) => {
    const match =
      /translate\(([-\d.]+) ([-\d.]+)\) rotate\(([-\d.]+)\)(?: matrix\(([-\d.]+) ([-\d.]+) ([-\d.]+) ([-\d.]+) 0 0\))?/.exec(
        eye.getAttribute('transform') ?? ''
      )

    const surface = match?.[4] ? ([4, 5, 6, 7].map(i => Number(match[i])) as [number, number, number, number]) : null

    return {
      angle: Number(match?.[3]),
      surface: surface ?? ([1, 0, 0, 1] as const),
      x: Number(match?.[1]),
      y: Number(match?.[2])
    }
  }

  const attentionOf = (eye: Element) => (parse(eye).angle + 11) / (FIGURE_TILT_DEGREES + 11)

  const move = (target: Element, x: number, y: number) =>
    target.dispatchEvent(new MouseEvent('pointermove', { bubbles: true, clientX: x, clientY: y }))

  beforeEach(() => {
    reduced = false
    queue = []
    clock = 0
    vi.stubGlobal('requestAnimationFrame', (cb: FrameRequestCallback) => queue.push(cb))
    vi.stubGlobal('cancelAnimationFrame', () => undefined)
    window.matchMedia = (() => ({ matches: reduced })) as unknown as typeof window.matchMedia
    stop = startFaceGaze()
  })

  afterEach(() => {
    stop()
    vi.unstubAllGlobals()
  })

  it('eases attention up on entering and settles in about 0.4 seconds', () => {
    const { left, scope } = mount()

    move(scope, 120, 120)
    frames(1)
    expect(attentionOf(left)).toBeGreaterThan(0)
    expect(attentionOf(left)).toBeLessThan(0.3)

    let previous = attentionOf(left)

    for (let i = 0; i < 23; i++) {
      frames(1)
      expect(attentionOf(left)).toBeGreaterThanOrEqual(previous)
      previous = attentionOf(left)
    }

    expect(previous).toBeGreaterThan(0.93)
    expect(previous).toBeLessThan(1)
  })

  it('eases attention back down on leaving and restores the baked pose exactly', () => {
    const { left, outside, right, scope } = mount()

    move(scope, 400, 120)
    frames(60)
    expect(attentionOf(left)).toBeCloseTo(1, 2)
    move(outside, 400, 120)
    frames(24)
    expect(attentionOf(left)).toBeLessThan(0.07)
    frames(120)
    expect(left.getAttribute('transform')).toBe(REST_LEFT)
    expect(right.getAttribute('transform')).toBe(REST_RIGHT)
    expect(queue).toHaveLength(0)
  })

  it('looks toward the pointer at full attention', () => {
    const { left, right, scope } = mount()

    move(scope, 5000, 120)
    frames(120)
    expect((parse(left).x + parse(right).x) / 2).toBeGreaterThan(50 + 12)
    expect(parse(right).surface[0]).toBeLessThan(0.8)
    move(scope, -5000, 120)
    frames(120)
    expect((parse(left).x + parse(right).x) / 2).toBeLessThan(50 - 12)
    expect(parse(left).surface[0]).toBeLessThan(0.8)
  })

  it('drives math faces through the same eyes', () => {
    const { left, scope } = mount('math')

    move(scope, 120, 120)
    frames(60)
    expect(parse(left).angle).toBeCloseTo(FIGURE_TILT_DEGREES, 1)
  })

  it('parks the frame loop once the eyes rest on a still pointer', () => {
    const { scope } = mount()

    move(scope, 400, 120)
    frames(400)
    expect(queue).toHaveLength(0)
  })

  it('applies nothing under reduced motion', () => {
    reduced = true
    const { left, scope } = mount()

    move(scope, 400, 120)
    frames(5)
    expect(left.getAttribute('transform')).toBe(REST_LEFT)
  })

  it('installs one listener however many times it starts', () => {
    const second = startFaceGaze()
    const { scope } = mount()

    move(scope, 400, 120)
    expect(queue).toHaveLength(1)
    second()
  })

  it('keeps the eyes inside the body while mood wander shifts the gaze group', () => {
    const { left, right, scope } = mount('blob', 'translate(3.6 -3.6)')

    for (const pointer of [5000, -5000]) {
      move(scope, pointer, 120)
      frames(120)

      for (const eye of [left, right]) {
        const pose = parse(eye)
        const { x, y } = pose
        const { x: hx, y: hy } = extent(pose)

        expect(x + 3.6 - hx).toBeGreaterThanOrEqual(10 - 1e-6)
        expect(x + 3.6 + hx).toBeLessThanOrEqual(90 + 1e-6)
        expect(y - 3.6 - hy).toBeGreaterThanOrEqual(10 - 1e-6)
        expect(y - 3.6 + hy).toBeLessThanOrEqual(90 + 1e-6)
      }
    }
  })

  it('restores the pose a re-render baked in mid-hover, not the one first seen', () => {
    const { left, outside, right, scope } = mount()
    const NEXT_LEFT = 'translate(55 50) rotate(-11)'
    const NEXT_RIGHT = 'translate(74 50) rotate(-11)'

    move(scope, 400, 120)
    frames(60)

    left.setAttribute('data-hb-rest', NEXT_LEFT)
    left.setAttribute('transform', NEXT_LEFT)
    right.setAttribute('data-hb-rest', NEXT_RIGHT)
    right.setAttribute('transform', NEXT_RIGHT)
    scope.querySelector('[data-hb-gaze]')!.setAttribute('data-hb-bounds', '10 30 90 90')
    frames(10)

    move(outside, 400, 120)
    frames(200)

    expect(left.getAttribute('transform')).toBe(NEXT_LEFT)
    expect(right.getAttribute('transform')).toBe(NEXT_RIGHT)
  })

  it('follows a changed body box while hovered', () => {
    const { left, scope } = mount()

    move(scope, 120, 120)
    frames(60)

    const before = parse(left).y

    scope.querySelector('[data-hb-gaze]')!.setAttribute('data-hb-bounds', '10 50 90 90')
    move(scope, 120, 120)
    frames(60)

    expect(parse(left).y).toBeGreaterThan(before)
  })
})
