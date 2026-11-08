import { curveEye, parseTransform, readEyeSize, readSurfaceSpec, type SurfaceSpec } from './eye-frame'
import { eyesDriven, prefersReducedMotion } from './face-driver'

export interface GazePoint {
  x: number
  y: number
}

export type GazeOffset = GazePoint

export interface EyeRest {
  height: number
  slant: number
  width: number
  x: number
  y: number
}

export interface BodyBounds {
  maxX: number
  maxY: number
  minX: number
  minY: number
}

export interface EyeRig {
  bounds: BodyBounds
  left: EyeRest
  right: EyeRest
}

export interface EyePose {
  angle: number
  x: number
  y: number
}

export const FIGURE_TILT_DEGREES = 14
export const ATTENTION_GAP = 1.35
export const ATTENTION_LIFT = 0.04
export const GAZE_REACH: GazeOffset = { x: 0.22, y: 0.18 }
export const GAZE_FULL_RADIUS = 0.5
export const GAZE_SMOOTHING_RATE = 14
export const ATTENTION_RATE = 9.5
export const GAZE_MAX_FRAME_SECONDS = 0.05
export const GAZE_SETTLE = 0.003
export const ATTENTION_SETTLE = 0.003

const SCOPE_SELECTOR = '[data-bot-gaze-scope]'
const FACE_SELECTOR = 'svg[data-bot-face]'
const EYES_SELECTOR = '[data-hb-gaze]'
const EYE_SELECTOR = '[data-hb-eye]'
const FIRST_FRAME_SECONDS = 1 / 60
const CENTRED: GazeOffset = { x: 0, y: 0 }
const EYE_TRANSFORM = /translate\(([-\d.]+)[ ,]+([-\d.]+)\)\s*rotate\(([-\d.]+)\)/
const REST_ATTRIBUTE = 'data-hb-rest'
const MASK_IDENTITY_ATTRIBUTE = 'data-hb-mask'
const TILT_RADIANS = (FIGURE_TILT_DEGREES * Math.PI) / 180

interface FaceGaze {
  attention: number
  attentionTarget: number
  eyes: [SVGGElement, SVGGElement]
  gaze: GazeOffset
  gazeTarget: GazeOffset
  group: SVGGElement
  identity: string
  rig: EyeRig
  surface: SurfaceSpec
}

type FaceParts = Omit<FaceGaze, 'attention' | 'attentionTarget' | 'gaze' | 'gazeTarget'>

export function gazeOffset(origin: GazePoint, faceWidth: number, pointer: GazePoint): GazeOffset {
  const dx = pointer.x - origin.x
  const dy = pointer.y - origin.y
  const distance = Math.hypot(dx, dy)

  if (distance === 0) {
    return CENTRED
  }

  const strength = Math.min(1, distance / Math.max(1, faceWidth * GAZE_FULL_RADIUS))

  return { x: (dx / distance) * strength, y: (dy / distance) * strength }
}

function smoothing(seconds: number, rate: number): number {
  return 1 - Math.exp(-Math.min(Math.max(seconds, 0), GAZE_MAX_FRAME_SECONDS) * rate)
}

export function easeToward(current: GazeOffset, target: GazeOffset, seconds: number): GazeOffset {
  const step = smoothing(seconds, GAZE_SMOOTHING_RATE)

  return { x: current.x + (target.x - current.x) * step, y: current.y + (target.y - current.y) * step }
}

export function easeAttention(current: number, target: number, seconds: number): number {
  return current + (target - current) * smoothing(seconds, ATTENTION_RATE)
}

function lerp(from: number, to: number, amount: number): number {
  return from + (to - from) * amount
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value))
}

function shiftWithin(shift: number, lows: number[], highs: number[]): number {
  const low = Math.max(...lows)
  const high = Math.min(...highs)

  return low > high ? (low + high) / 2 : clamp(shift, low, high)
}

function halfExtent(eye: EyeRest, angle: number): GazePoint {
  const radians = (angle * Math.PI) / 180
  const cos = Math.abs(Math.cos(radians))
  const sin = Math.abs(Math.sin(radians))

  return { x: (cos * eye.width + sin * eye.height) / 2, y: (sin * eye.width + cos * eye.height) / 2 }
}

export function composeEyes(rig: EyeRig, attention: number, gaze: GazeOffset): [EyePose, EyePose] {
  const weight = clamp(attention, 0, 1)
  const { bounds, left, right } = rig
  const width = bounds.maxX - bounds.minX
  const height = bounds.maxY - bounds.minY
  const restMidX = (left.x + right.x) / 2
  const restMidY = (left.y + right.y) / 2
  const midX = lerp(restMidX, (bounds.minX + bounds.maxX) / 2, weight)
  const midY = lerp(restMidY, (bounds.minY + bounds.maxY) / 2 - ATTENTION_LIFT * height, weight)
  const lookX = gaze.x * GAZE_REACH.x * width * weight
  const lookY = gaze.y * GAZE_REACH.y * height * weight
  const cos = Math.cos(TILT_RADIANS)
  const sin = Math.sin(TILT_RADIANS)
  const levelGap = Math.hypot(right.x - left.x, right.y - left.y) * ATTENTION_GAP

  const eyes = [left, right].map((eye, index) => {
    const angle = lerp(eye.slant, FIGURE_TILT_DEGREES, weight)
    const side = index === 0 ? -0.5 : 0.5

    return {
      angle,
      half: halfExtent(eye, angle),
      x: midX + lerp(eye.x - restMidX, side * levelGap * cos, weight),
      y: midY + lerp(eye.y - restMidY, side * levelGap * sin, weight)
    }
  })

  const shiftX = shiftWithin(
    lookX * cos - lookY * sin,
    eyes.map(eye => bounds.minX + eye.half.x - eye.x),
    eyes.map(eye => bounds.maxX - eye.half.x - eye.x)
  )

  const shiftY = shiftWithin(
    lookX * sin + lookY * cos,
    eyes.map(eye => bounds.minY + eye.half.y - eye.y),
    eyes.map(eye => bounds.maxY - eye.half.y - eye.y)
  )

  const [first, second] = eyes.map(eye => ({ angle: eye.angle, x: eye.x + shiftX, y: eye.y + shiftY }))

  return [first, second]
}

function readEyeRest(eye: SVGGElement): EyeRest | null {
  const match = EYE_TRANSFORM.exec(eye.getAttribute(REST_ATTRIBUTE) ?? '')
  const size = readEyeSize(eye)

  if (!match || !size) {
    return null
  }

  return { ...size, slant: Number(match[3]), x: Number(match[1]), y: Number(match[2]) }
}

function readBounds(group: SVGGElement): BodyBounds | null {
  const [minX, minY, maxX, maxY] = (group.getAttribute('data-hb-bounds') ?? '')
    .trim()
    .split(/[\s,]+/)
    .map(Number)

  return [minX, minY, maxX, maxY].every(Number.isFinite) && maxX > minX && maxY > minY
    ? { maxX, maxY, minX, minY }
    : null
}

function faceIdentity(group: SVGGElement, eyes: SVGGElement[]): string {
  return [
    group.getAttribute('data-hb-bounds'),
    group.getAttribute(MASK_IDENTITY_ATTRIBUTE),
    ...eyes.map(eye => eye.getAttribute(REST_ATTRIBUTE))
  ].join('|')
}

function readFace(svg: SVGSVGElement): FaceParts | null {
  const group = svg.querySelector<SVGGElement>(EYES_SELECTOR)
  const bounds = group && readBounds(group)
  const surface = group && readSurfaceSpec(group)
  const [leftEye, rightEye] = group ? Array.from(group.querySelectorAll<SVGGElement>(EYE_SELECTOR)) : []
  const left = leftEye && readEyeRest(leftEye)
  const right = rightEye && readEyeRest(rightEye)

  if (!group || !bounds || !surface || !left || !right) {
    return null
  }

  return {
    eyes: [leftEye, rightEye],
    group,
    identity: faceIdentity(group, [leftEye, rightEye]),
    rig: { bounds, left, right },
    surface
  }
}

function faceTracked(svg: SVGSVGElement): boolean {
  return svg.hasAttribute('data-hb-math') || svg.getAttribute('data-bot-gaze') === 'eyes'
}

function paintEye(face: FaceParts, index: number, transform: string) {
  const eye = face.eyes[index]
  const size = index === 0 ? face.rig.left : face.rig.right
  const d = curveEye(face.surface, size, parseTransform(transform))

  eye.setAttribute('transform', transform)
  eye.querySelector('path')?.setAttribute('d', d)
}

function writeEyes(face: FaceGaze) {
  composeEyes(face.rig, face.attention, face.gaze).forEach((pose, index) => {
    paintEye(face, index, `translate(${pose.x.toFixed(3)} ${pose.y.toFixed(3)}) rotate(${pose.angle.toFixed(3)})`)
  })
}

function restoreEyes(face: FaceParts) {
  face.eyes.forEach((eye, index) => {
    const rest = eye.getAttribute(REST_ATTRIBUTE)

    if (rest) {
      paintEye(face, index, rest)
    }
  })
}

function scopeOf(target: EventTarget | null): Element | null {
  return target instanceof Element ? target.closest(SCOPE_SELECTOR) : null
}

function reachedTarget(face: FaceGaze): boolean {
  return (
    Math.abs(face.attentionTarget - face.attention) < ATTENTION_SETTLE &&
    Math.abs(face.gazeTarget.x - face.gaze.x) < GAZE_SETTLE &&
    Math.abs(face.gazeTarget.y - face.gaze.y) < GAZE_SETTLE
  )
}

const faces = new Map<SVGSVGElement, FaceGaze>()

let activeStop: (() => void) | null = null

export function startFaceGaze(): () => void {
  if (activeStop) {
    return activeStop
  }

  let frame = 0
  let running = false
  let lastTime: null | number = null
  let latest: { target: EventTarget | null; x: number; y: number } | null = null

  const track = (svg: SVGSVGElement): FaceGaze | null => {
    const known = faces.get(svg)

    if (known) {
      return known
    }

    const parts = faceTracked(svg) && !eyesDriven(svg) ? readFace(svg) : null

    if (!parts) {
      return null
    }

    const face = { ...parts, attention: 0, attentionTarget: 0, gaze: CENTRED, gazeTarget: CENTRED }

    faces.set(svg, face)

    return face
  }

  const refreshRig = (face: FaceGaze, svg: SVGSVGElement): boolean => {
    if (faceIdentity(face.group, face.eyes) === face.identity) {
      return true
    }

    const parts = readFace(svg)

    if (!parts) {
      return false
    }

    Object.assign(face, parts)

    return true
  }

  const retarget = () => {
    if (!latest) {
      return
    }

    const { target, x, y } = latest
    const scope = prefersReducedMotion() ? null : scopeOf(target)
    const inScope = new Set<SVGSVGElement>()

    if (scope) {
      for (const svg of scope.querySelectorAll<SVGSVGElement>(FACE_SELECTOR)) {
        const face = track(svg)

        if (face) {
          const box = svg.getBoundingClientRect()

          face.attentionTarget = 1
          face.gazeTarget = gazeOffset({ x: box.left + box.width / 2, y: box.top + box.height / 2 }, box.width, {
            x,
            y
          })
          inScope.add(svg)
        }
      }
    }

    for (const [svg, face] of faces) {
      if (!inScope.has(svg)) {
        face.attentionTarget = 0
        face.gazeTarget = CENTRED
      }
    }

    latest = null
  }

  const advance = (face: FaceGaze, seconds: number): boolean => {
    face.attention = easeAttention(face.attention, face.attentionTarget, seconds)
    face.gaze = easeToward(face.gaze, face.gazeTarget, seconds)

    if (!reachedTarget(face)) {
      writeEyes(face)

      return true
    }

    face.attention = face.attentionTarget
    face.gaze = face.gazeTarget

    if (face.attentionTarget === 0) {
      restoreEyes(face)
    } else {
      writeEyes(face)
    }

    return false
  }

  const step = (now: number) => {
    frame = 0
    const seconds = lastTime === null ? FIRST_FRAME_SECONDS : (now - lastTime) / 1000

    lastTime = now
    retarget()

    let moving = false

    for (const [svg, face] of faces) {
      if (!svg.isConnected || !face.eyes[0].isConnected || !refreshRig(face, svg)) {
        faces.delete(svg)

        continue
      }

      if (eyesDriven(svg)) {
        faces.delete(svg)

        continue
      }

      if (advance(face, seconds)) {
        moving = true
      } else if (face.attentionTarget === 0) {
        faces.delete(svg)
      }
    }

    if (moving || latest) {
      frame = requestAnimationFrame(step)
    } else {
      running = false
      lastTime = null
    }
  }

  const schedule = () => {
    if (!running) {
      running = true
      frame = requestAnimationFrame(step)
    }
  }

  const onPointerMove = (event: PointerEvent) => {
    latest = { target: event.target, x: event.clientX, y: event.clientY }
    schedule()
  }

  document.addEventListener('pointermove', onPointerMove, { passive: true })

  activeStop = () => {
    document.removeEventListener('pointermove', onPointerMove)

    if (frame) {
      cancelAnimationFrame(frame)
    }

    for (const face of faces.values()) {
      restoreEyes(face)
    }

    faces.clear()
    running = false
    frame = 0
    lastTime = null
    latest = null
    activeStop = null
  }

  return activeStop
}
