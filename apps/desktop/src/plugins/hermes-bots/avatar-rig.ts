import type { AvatarPose } from './avatar-motion'
import {
  type Box,
  type EyeSize,
  invert,
  type Matrix,
  multiply,
  parseTransform,
  pillPath,
  surfaceBounds,
  surfaceFor,
  type SurfaceSpec,
  transformPoint
} from './eye-frame'
import { type EyeSurface, flatten, type Point, type Ring } from './eye-surface'

export interface EyePlacement {
  angle: number
  scale: number
  x: number
  y: number
}

export interface AvatarRig {
  facing: EyePlacement[]
  frame: Matrix
  pivot: Point
  rest: EyePlacement[]
  size: EyeSize
  span: number
  surface: EyeSurface
  travel: number
}

export interface RigSpec {
  facesRest: boolean
  rests: Matrix[]
  size: EyeSize
  surface: SurfaceSpec
  travel: null | number
}

export interface PaintedEye {
  eye: Matrix
  local: Matrix
  rings: Ring[]
}

export const FACING_HEIGHT = 0.34
export const FACING_SEPARATION = 0.3
export const FACING_DROP = 0.01

const ARC_STEPS = 16
const CAP_STEPS = 8
const HAPPY_THRESHOLD = 0.5

export function placementOf([a, b, , , e, f]: Matrix): EyePlacement {
  return { angle: Math.atan2(b, a), scale: Math.hypot(a, b), x: e, y: f }
}

export function placementMatrix({ angle, scale, x, y }: EyePlacement): Matrix {
  const cos = scale * Math.cos(angle)
  const sin = scale * Math.sin(angle)

  return [cos, sin, -sin, cos, x, y]
}

function blendPlacement(from: EyePlacement, to: EyePlacement, amount: number): EyePlacement {
  return {
    angle: from.angle + (to.angle - from.angle) * amount,
    scale: from.scale + (to.scale - from.scale) * amount,
    x: from.x + (to.x - from.x) * amount,
    y: from.y + (to.y - from.y) * amount
  }
}

export function facingPlacements(rest: EyePlacement[], size: EyeSize, bounds: Box): EyePlacement[] {
  const span = (bounds.maxX - bounds.minX + (bounds.maxY - bounds.minY)) / 2
  const scale = (span * FACING_HEIGHT) / size.height
  const separation = span * FACING_SEPARATION
  const y = (bounds.minY + bounds.maxY) / 2 + span * FACING_DROP
  const x = (bounds.minX + bounds.maxX) / 2

  return rest.map((_, index) => {
    const side = rest.length < 2 ? 0 : index / (rest.length - 1) - 0.5

    return { angle: 0, scale, x: x + side * separation, y }
  })
}

export function createRig(spec: RigSpec): AvatarRig {
  const frame = parseTransform(spec.surface.frame)
  const bounds = surfaceBounds(spec.surface)
  const rest = spec.rests.map(eye => placementOf(multiply(frame, eye)))
  const span = (bounds.maxX - bounds.minX + (bounds.maxY - bounds.minY)) / 2

  return {
    facing: spec.facesRest ? rest : facingPlacements(rest, spec.size, bounds),
    frame,
    pivot: [(bounds.minX + bounds.maxX) / 2, (bounds.minY + bounds.maxY) / 2],
    rest,
    size: spec.size,
    span,
    surface: surfaceFor(spec.surface),
    travel: spec.travel ?? span
  }
}

function strokedArc(points: Point[], halfWidth: number): Ring {
  const normals = points.slice(1).map(([x, y], index): Point => {
    const [fromX, fromY] = points[index]
    const length = Math.hypot(x - fromX, y - fromY) || 1

    return [-(y - fromY) / length, (x - fromX) / length]
  })

  const offsets = points.map((_, index): Point => {
    const before = normals[Math.max(0, index - 1)]
    const after = normals[Math.min(normals.length - 1, index)]
    const sumX = before[0] + after[0]
    const sumY = before[1] + after[1]
    const length = Math.hypot(sumX, sumY) || 1
    const miter = halfWidth / Math.max(0.5, (sumX * after[0] + sumY * after[1]) / length)

    return [(sumX / length) * miter, (sumY / length) * miter]
  })

  const cap = (centre: Point, start: number, sweep: number): Point[] =>
    Array.from({ length: CAP_STEPS - 1 }, (_, step) => {
      const angle = start + (sweep * (step + 1)) / CAP_STEPS

      return [centre[0] + halfWidth * Math.cos(angle), centre[1] + halfWidth * Math.sin(angle)]
    })

  const last = points.length - 1
  const tail = normals[normals.length - 1]
  const head = normals[0]

  return [
    ...points.map(([x, y], index): Point => [x + offsets[index][0], y + offsets[index][1]]),
    ...cap(points[last], Math.atan2(tail[1], tail[0]), -Math.PI),
    ...points.map(([x, y], index): Point => [x - offsets[index][0], y - offsets[index][1]]).reverse(),
    ...cap(points[0], Math.atan2(head[1], head[0]) + Math.PI, -Math.PI)
  ]
}

function happyArc({ height, width }: EyeSize): Ring {
  const thickness = Math.min(width, height) * 0.5
  const reach = Math.max(height * 0.65, width * 1.3)
  const radius = (reach - thickness) / 2

  const points = Array.from({ length: ARC_STEPS + 1 }, (_, step): Point => {
    const angle = ((160 + (220 * step) / ARC_STEPS) * Math.PI) / 180

    return [radius * Math.cos(angle), radius * Math.sin(angle) + radius * 0.33]
  })

  return strokedArc(points, thickness / 2)
}

export function eyeOutline(size: EyeSize, pose: AvatarPose): Ring[] {
  if (pose.eyeHappy >= HAPPY_THRESHOLD) {
    const grow = 0.6 + 0.8 * (pose.eyeHappy - HAPPY_THRESHOLD)

    return [happyArc(size).map(([x, y]): Point => [x * grow, y * grow])]
  }

  const rounded = size.height + (size.width - size.height) * pose.eyeDot
  const squash = 1 - 1.3 * pose.eyeHappy
  const height = Math.max(0.01, rounded * pose.eyeOpen * squash)

  return flatten(pillPath({ height, width: size.width }))
}

function centroid(placements: EyePlacement[]): Point {
  const count = placements.length

  return [placements.reduce((sum, { x }) => sum + x, 0) / count, placements.reduce((sum, { y }) => sum + y, 0) / count]
}

export function paintEyes(rig: AvatarRig, pose: AvatarPose): PaintedEye[] {
  const placements = rig.rest.map((rest, index) => blendPlacement(rest, rig.facing[index], pose.front))

  if (placements.length === 0) {
    return []
  }

  const [midX, midY] = centroid(placements)
  const roll = (pose.eyeRoll * Math.PI) / 180
  const cos = Math.cos(roll)
  const sin = Math.sin(roll)
  const outline = eyeOutline(rig.size, pose)

  return placements.map(placement => {
    const dx = (placement.x - midX) * pose.eyeSpread
    const dy = (placement.y - midY) * pose.eyeSpread
    const x = midX + dx * cos - dy * sin + pose.eyeX * rig.travel
    const y = midY + dx * sin + dy * cos + pose.eyeY * rig.travel

    const eye = placementMatrix({
      angle: placement.angle + roll,
      scale: placement.scale * pose.eyeScale,
      x,
      y
    })

    const rings = rig.surface.project(
      outline.map(ring => ring.map(point => transformPoint(eye, point))),
      [x, y]
    )

    return { eye, local: invert(eye), rings }
  })
}
