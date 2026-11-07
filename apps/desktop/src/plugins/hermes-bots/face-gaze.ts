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

export type SurfaceMap = readonly [number, number, number, number]

export interface EyePose {
  angle: number
  surface: SurfaceMap
  x: number
  y: number
}

export const FIGURE_TILT_DEGREES = 14
export const ATTENTION_GAP = 1.35
export const ATTENTION_LIFT = 0.04
export const GAZE_REACH: GazeOffset = { x: 0.22, y: 0.18 }
export const GAZE_FULL_RADIUS = 0.5
export const GAZE_TURN_DEGREES = 40
export const GAZE_LIMB_DEGREES = 85
export const GAZE_SMOOTHING_RATE = 14
export const ATTENTION_RATE = 9.5
export const GAZE_MAX_FRAME_SECONDS = 0.05
export const GAZE_SETTLE = 0.003
export const ATTENTION_SETTLE = 0.003

const SCOPE_SELECTOR = '[data-bot-gaze-scope]'
const FACE_SELECTOR = 'svg[data-bot-face]'
const EYES_SELECTOR = '[data-hb-gaze]'
const EYE_SELECTOR = '[data-hb-eye]'
const REDUCED_MOTION_QUERY = '(prefers-reduced-motion: reduce)'
const FIRST_FRAME_SECONDS = 1 / 60
const CENTRED: GazeOffset = { x: 0, y: 0 }
const EYE_TRANSFORM = /translate\(([-\d.]+)[ ,]+([-\d.]+)\)\s*rotate\(([-\d.]+)\)/
const GROUP_TRANSLATE = /translate\(\s*([-\d.]+)[ ,]+([-\d.]+)\s*\)/
const REST_ATTRIBUTE = 'data-hb-rest'
const TILT_RADIANS = (FIGURE_TILT_DEGREES * Math.PI) / 180
const TURN_RADIANS = (GAZE_TURN_DEGREES * Math.PI) / 180
const LIMB_RADIANS = (GAZE_LIMB_DEGREES * Math.PI) / 180
const FLAT: SurfaceMap = [1, 0, 0, 1]

type Vec3 = readonly [number, number, number]

interface GazeSphere {
  pitch: number
  radius: number
  yaw: number
}

interface FaceGaze {
  attention: number
  attentionTarget: number
  eyes: [SVGGElement, SVGGElement]
  gaze: GazeOffset
  gazeTarget: GazeOffset
  group: SVGGElement
  identity: string
  rig: EyeRig
}

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

function shiftWithin(lows: number[], highs: number[]): number {
  const low = Math.max(...lows)
  const high = Math.min(...highs)

  return low > high ? (low + high) / 2 : clamp(0, low, high)
}

function rotation(radians: number): SurfaceMap {
  const cos = Math.cos(radians)
  const sin = Math.sin(radians)

  return [cos, sin, -sin, cos]
}

function compose(m: SurfaceMap, n: SurfaceMap): SurfaceMap {
  return [m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1], m[0] * n[2] + m[2] * n[3], m[1] * n[2] + m[3] * n[3]]
}

function invert([a, b, c, d]: SurfaceMap): SurfaceMap {
  const det = a * d - b * c

  return [d / det, -b / det, -c / det, a / det]
}

function apply(m: SurfaceMap, point: GazePoint): GazePoint {
  return { x: m[0] * point.x + m[2] * point.y, y: m[1] * point.x + m[3] * point.y }
}

function normalize([x, y, z]: Vec3): Vec3 {
  const length = Math.hypot(x, y, z)

  return [x / length, y / length, z / length]
}

function cross([ax, ay, az]: Vec3, [bx, by, bz]: Vec3): Vec3 {
  return [ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx]
}

function turn([x, y, z]: Vec3, yaw: number, pitch: number): Vec3 {
  const turnedX = x * Math.cos(yaw) + z * Math.sin(yaw)
  const turnedZ = z * Math.cos(yaw) - x * Math.sin(yaw)

  return [turnedX, y * Math.cos(pitch) + turnedZ * Math.sin(pitch), turnedZ * Math.cos(pitch) - y * Math.sin(pitch)]
}

function projected(u: Vec3, v: Vec3): SurfaceMap {
  return [u[0], u[1], v[0], v[1]]
}

function gazeSphere(eyes: { eye: EyeRest; offset: GazePoint }[], width: number, height: number): GazeSphere {
  const reachX = GAZE_REACH.x * width
  const reachY = GAZE_REACH.y * height

  const extent = Math.max(
    ...eyes.map(({ eye, offset }) => Math.hypot(offset.x, offset.y) + Math.hypot(eye.width, eye.height) / 2)
  )

  const radius = Math.max(
    reachX / Math.sin(TURN_RADIANS),
    reachY / Math.sin(TURN_RADIANS),
    extent / Math.sin(LIMB_RADIANS - TURN_RADIANS)
  )

  return { pitch: Math.asin(reachY / radius), radius, yaw: Math.asin(reachX / radius) }
}

function turnOnSphere(
  offset: GazePoint,
  radius: number,
  yaw: number,
  pitch: number
): { offset: GazePoint; surface: SurfaceMap } {
  if (yaw === 0 && pitch === 0) {
    return { offset, surface: FLAT }
  }

  const normal: Vec3 = [
    offset.x / radius,
    offset.y / radius,
    Math.sqrt(Math.max(0, 1 - (offset.x * offset.x + offset.y * offset.y) / (radius * radius)))
  ]

  const across = normalize([1 - normal[0] * normal[0], -normal[0] * normal[1], -normal[0] * normal[2]])
  const down = cross(normal, across)
  const [x, y] = turn(normal, yaw, pitch)

  return {
    offset: { x: x * radius, y: y * radius },
    surface: compose(projected(turn(across, yaw, pitch), turn(down, yaw, pitch)), invert(projected(across, down)))
  }
}

export function composeEyes(
  rig: EyeRig,
  attention: number,
  gaze: GazeOffset,
  wander: GazePoint = CENTRED
): [EyePose, EyePose] {
  const weight = clamp(attention, 0, 1)
  const { left, right } = rig

  const bounds = {
    maxX: rig.bounds.maxX - wander.x,
    maxY: rig.bounds.maxY - wander.y,
    minX: rig.bounds.minX - wander.x,
    minY: rig.bounds.minY - wander.y
  }

  const width = bounds.maxX - bounds.minX
  const height = bounds.maxY - bounds.minY
  const restMidX = (left.x + right.x) / 2
  const restMidY = (left.y + right.y) / 2
  const midX = lerp(restMidX, (bounds.minX + bounds.maxX) / 2, weight)
  const midY = lerp(restMidY, (bounds.minY + bounds.maxY) / 2 - ATTENTION_LIFT * height, weight)
  const cos = Math.cos(TILT_RADIANS)
  const sin = Math.sin(TILT_RADIANS)
  const levelGap = Math.hypot(right.x - left.x, right.y - left.y) * ATTENTION_GAP
  const toScreen = rotation(-TILT_RADIANS)
  const toFigure = rotation(TILT_RADIANS)

  const level = [left, right].map((eye, index) => {
    const side = index === 0 ? -0.5 : 0.5

    return {
      angle: lerp(eye.slant, FIGURE_TILT_DEGREES, weight),
      eye,
      offset: {
        x: lerp(eye.x - restMidX, side * levelGap * cos, weight),
        y: lerp(eye.y - restMidY, side * levelGap * sin, weight)
      }
    }
  })

  const sphere = gazeSphere(level, width, height)
  const yaw = gaze.x * sphere.yaw * weight
  const pitch = gaze.y * sphere.pitch * weight

  const eyes = level.map(({ angle, eye, offset }) => {
    const turned = turnOnSphere(apply(toScreen, offset), sphere.radius, yaw, pitch)
    const along = apply(toFigure, turned.offset)
    const radians = (angle * Math.PI) / 180
    const shape = compose(compose(toFigure, turned.surface), compose(toScreen, rotation(radians)))

    const surface = turned.surface === FLAT ? FLAT : compose(rotation(-radians), shape)

    return {
      angle,
      half: {
        x: (Math.abs(shape[0]) * eye.width + Math.abs(shape[2]) * eye.height) / 2,
        y: (Math.abs(shape[1]) * eye.width + Math.abs(shape[3]) * eye.height) / 2
      },
      surface,
      x: midX + along.x,
      y: midY + along.y
    }
  })

  const shiftX = shiftWithin(
    eyes.map(eye => bounds.minX + eye.half.x - eye.x),
    eyes.map(eye => bounds.maxX - eye.half.x - eye.x)
  )

  const shiftY = shiftWithin(
    eyes.map(eye => bounds.minY + eye.half.y - eye.y),
    eyes.map(eye => bounds.maxY - eye.half.y - eye.y)
  )

  const [first, second] = eyes.map(eye => ({
    angle: eye.angle,
    surface: eye.surface,
    x: eye.x + shiftX,
    y: eye.y + shiftY
  }))

  return [first, second]
}

function readEyeRest(eye: SVGGElement): EyeRest | null {
  const match = EYE_TRANSFORM.exec(eye.getAttribute(REST_ATTRIBUTE) ?? '')
  const rect = eye.querySelector('rect')
  const width = Number(rect?.getAttribute('width'))
  const height = Number(rect?.getAttribute('height'))

  if (!match || !(width > 0) || !(height > 0)) {
    return null
  }

  return { height, slant: Number(match[3]), width, x: Number(match[1]), y: Number(match[2]) }
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
  return [group.getAttribute('data-hb-bounds'), ...eyes.map(eye => eye.getAttribute(REST_ATTRIBUTE))].join('|')
}

function readFace(svg: SVGSVGElement): Omit<FaceGaze, 'attention' | 'attentionTarget' | 'gaze' | 'gazeTarget'> | null {
  const group = svg.querySelector<SVGGElement>(EYES_SELECTOR)
  const bounds = group && readBounds(group)
  const [leftEye, rightEye] = group ? Array.from(group.querySelectorAll<SVGGElement>(EYE_SELECTOR)) : []
  const left = leftEye && readEyeRest(leftEye)
  const right = rightEye && readEyeRest(rightEye)

  if (!group || !bounds || !left || !right) {
    return null
  }

  return {
    eyes: [leftEye, rightEye],
    group,
    identity: faceIdentity(group, [leftEye, rightEye]),
    rig: { bounds, left, right }
  }
}

function readWander(group: SVGGElement): GazePoint {
  const match = GROUP_TRANSLATE.exec(group.getAttribute('transform') ?? '')

  return match ? { x: Number(match[1]), y: Number(match[2]) } : CENTRED
}

function faceTracked(svg: SVGSVGElement): boolean {
  return svg.hasAttribute('data-hb-math') || svg.getAttribute('data-bot-gaze') === 'eyes'
}

function writeEyes(face: FaceGaze) {
  composeEyes(face.rig, face.attention, face.gaze, readWander(face.group)).forEach((pose, index) => {
    face.eyes[index].setAttribute(
      'transform',
      `translate(${pose.x.toFixed(3)} ${pose.y.toFixed(3)}) rotate(${pose.angle.toFixed(3)}) matrix(${pose.surface.map(value => value.toFixed(4)).join(' ')} 0 0)`
    )
  })
}

function restoreEyes(face: FaceGaze) {
  face.eyes.forEach(eye => {
    const rest = eye.getAttribute(REST_ATTRIBUTE)

    if (rest) {
      eye.setAttribute('transform', rest)
    }
  })
}

function prefersReducedMotion(): boolean {
  return typeof window.matchMedia === 'function' && window.matchMedia(REDUCED_MOTION_QUERY).matches
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

let activeStop: (() => void) | null = null

export function startFaceGaze(): () => void {
  if (activeStop) {
    return activeStop
  }

  const faces = new Map<SVGSVGElement, FaceGaze>()
  let frame = 0
  let running = false
  let lastTime: null | number = null
  let latest: { target: EventTarget | null; x: number; y: number } | null = null

  const track = (svg: SVGSVGElement): FaceGaze | null => {
    const known = faces.get(svg)

    if (known) {
      return known
    }

    const parts = faceTracked(svg) ? readFace(svg) : null

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
