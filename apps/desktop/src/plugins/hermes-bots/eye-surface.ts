import { absolutize, normalize, parsePath } from 'path-data-parser'

export type Point = readonly [number, number]
export type Ring = Point[]

export interface MaskPart {
  reach: number
  rings: Ring[]
}

export interface EyeSurface {
  height: (point: Point) => number
  project: (rings: Ring[], centre: Point) => Ring[]
}

type Vector = readonly [number, number, number]

const SURFACE_CELLS = 48
const CURVE_STEPS = 8
const WALK_STEPS = 12
const SURFACE_BULGE = 1.3

const REMEMBERED = 64
const surfaces = new Map<string, EyeSurface>()

function mix(from: Point, to: Point, t: number): Point {
  return [from[0] + (to[0] - from[0]) * t, from[1] + (to[1] - from[1]) * t]
}

function cubicAt(p0: Point, p1: Point, p2: Point, p3: Point, t: number): Point {
  return mix(mix(mix(p0, p1, t), mix(p1, p2, t), t), mix(mix(p1, p2, t), mix(p2, p3, t), t), t)
}

function samples(point: (t: number) => Point): Point[] {
  return Array.from({ length: CURVE_STEPS }, (_, index) => point((index + 1) / CURVE_STEPS))
}

export function flatten(d: string): Ring[] {
  const rings: Ring[] = []
  let current: Point[] = []
  let cursor: Point = [0, 0]

  const finish = () => {
    if (current.length > 2) {
      rings.push(current)
    }

    current = []
  }

  for (const { data, key } of normalize(absolutize(parsePath(d)))) {
    const start = cursor

    if (key === 'M') {
      finish()
      cursor = [data[0], data[1]]
      current = [cursor]
    } else if (key === 'L') {
      const to: Point = [data[0], data[1]]

      current.push(...samples(t => mix(start, to, t)))
      cursor = to
    } else if (key === 'C') {
      const to: Point = [data[4], data[5]]

      current.push(...samples(t => cubicAt(start, [data[0], data[1]], [data[2], data[3]], to, t)))
      cursor = to
    } else if (key === 'Z' && current.length > 0) {
      const first = current[0]

      current.push(...samples(t => mix(start, first, t)))
      current.pop()
      cursor = first
      finish()
    }
  }

  finish()

  return rings
}

function plus(a: Vector, b: Vector): Vector {
  return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

function minus(a: Vector, b: Vector): Vector {
  return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

function times(a: Vector, k: number): Vector {
  return [a[0] * k, a[1] * k, a[2] * k]
}

function dot(a: Vector, b: Vector): number {
  return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

function cross(a: Vector, b: Vector): Vector {
  return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

function unit(v: Vector): Vector {
  const length = Math.sqrt(dot(v, v))

  return length > 0 ? times(v, 1 / length) : v
}

function segmentDistance(px: number, py: number, start: Point, end: Point): number {
  const ex = end[0] - start[0]
  const ey = end[1] - start[1]
  const span = ex * ex + ey * ey
  const t = span > 0 ? Math.max(0, Math.min(1, ((px - start[0]) * ex + (py - start[1]) * ey) / span)) : 0

  return Math.hypot(px - start[0] - ex * t, py - start[1] - ey * t)
}

function signedDepth(px: number, py: number, rings: Ring[]): number {
  let inside = false
  let nearest = Infinity

  for (const ring of rings) {
    for (let index = 0; index < ring.length; index++) {
      const end = ring[index]
      const start = ring[(index + ring.length - 1) % ring.length]

      if (
        start[1] > py !== end[1] > py &&
        px < start[0] + ((py - start[1]) / (end[1] - start[1])) * (end[0] - start[0])
      ) {
        inside = !inside
      }

      nearest = Math.min(nearest, segmentDistance(px, py, start, end))
    }
  }

  return inside ? nearest : -nearest
}

interface Box {
  maxX: number
  maxY: number
  minX: number
  minY: number
}

function boundsOf(parts: MaskPart[]): Box | null {
  const points = parts.flatMap(part =>
    part.rings.flatMap(ring => ring.map(([x, y]): [number, number, number] => [x, y, part.reach]))
  )

  if (points.length === 0) {
    return null
  }

  return {
    maxX: Math.max(...points.map(([x, , reach]) => x + reach)) + 1,
    maxY: Math.max(...points.map(([, y, reach]) => y + reach)) + 1,
    minX: Math.min(...points.map(([x, , reach]) => x - reach)) - 1,
    minY: Math.min(...points.map(([, y, reach]) => y - reach)) - 1
  }
}

interface Dome {
  deepest: number
  depths: Float64Array
}

const FLAT: EyeSurface = { height: () => 0, project: () => [] }

function buildDomes(parts: MaskPart[], box: Box, cellWidth: number, cellHeight: number): Dome[] {
  const stride = SURFACE_CELLS + 1

  return parts.flatMap(({ reach, rings }) => {
    const depths = new Float64Array(stride * stride)
    let deepest = -Infinity

    for (let row = 0; row < stride; row++) {
      for (let column = 0; column < stride; column++) {
        const depth = signedDepth(box.minX + column * cellWidth, box.minY + row * cellHeight, rings) + reach

        depths[row * stride + column] = depth
        deepest = Math.max(deepest, depth)
      }
    }

    return deepest > 0 ? [{ deepest, depths }] : []
  })
}

function createSurface(parts: MaskPart[]): EyeSurface {
  const box = boundsOf(parts)

  if (!box || !(box.maxX > box.minX) || !(box.maxY > box.minY)) {
    return FLAT
  }

  const cellWidth = (box.maxX - box.minX) / SURFACE_CELLS
  const cellHeight = (box.maxY - box.minY) / SURFACE_CELLS
  const domes = buildDomes(parts, box, cellWidth, cellHeight)
  const stride = SURFACE_CELLS + 1

  const height = ([px, py]: Point): number => {
    const x = (px - box.minX) / cellWidth
    const y = (py - box.minY) / cellHeight

    if (!(x >= 0 && y >= 0 && x <= SURFACE_CELLS && y <= SURFACE_CELLS)) {
      return 0
    }

    const column = Math.min(Math.floor(x), SURFACE_CELLS - 1)
    const row = Math.min(Math.floor(y), SURFACE_CELLS - 1)
    const fx = x - column
    const fy = y - row
    const corner = row * stride + column
    let highest = 0

    for (const { deepest, depths } of domes) {
      const top = depths[corner] * (1 - fx) + depths[corner + 1] * fx
      const bottom = depths[corner + stride] * (1 - fx) + depths[corner + stride + 1] * fx
      const depth = top * (1 - fy) + bottom * fy

      if (depth > 0) {
        highest = Math.max(highest, SURFACE_BULGE * Math.sqrt(depth * (2 * deepest - depth)))
      }
    }

    return highest
  }

  const slopeReach = Math.min(cellWidth, cellHeight) / 2

  const normal = ([px, py]: Point): Vector => {
    const slopeX = (height([px + slopeReach, py]) - height([px - slopeReach, py])) / (2 * slopeReach)
    const slopeY = (height([px, py + slopeReach]) - height([px, py - slopeReach])) / (2 * slopeReach)

    return unit([-slopeX, -slopeY, 1])
  }

  const place = (offset: Point, centre: Point, across: Vector, down: Vector): Point => {
    const length = Math.hypot(offset[0], offset[1])

    if (!(length > 0)) {
      return centre
    }

    let heading = unit(times(plus(times(across, offset[0]), times(down, offset[1])), 1 / length))
    let here: Vector = [centre[0], centre[1], height(centre)]
    const step = length / WALK_STEPS

    for (let walked = 0; walked < WALK_STEPS; walked++) {
      const ahead = plus(here, times(heading, step))
      const ground = height([ahead[0], ahead[1]])

      if (!(ground > 0)) {
        break
      }

      here = [ahead[0], ahead[1], ground]

      const tangent = normal([here[0], here[1]])

      heading = unit(minus(heading, times(tangent, dot(heading, tangent))))
    }

    return [here[0], here[1]]
  }

  const project = (rings: Ring[], centre: Point): Ring[] => {
    if (!(height(centre) > 0)) {
      return []
    }

    const up = normal(centre)
    const across = unit(minus([1, 0, 0], times(up, up[0])))
    const down = cross(up, across)

    return rings.map(ring =>
      ring.map(point => place([point[0] - centre[0], point[1] - centre[1]], centre, across, down))
    )
  }

  return { height, project }
}

export function sharedSurface(key: string, parts: () => MaskPart[]): EyeSurface {
  const known = surfaces.get(key)

  if (known) {
    return known
  }

  const surface = createSurface(parts())

  if (surfaces.size >= REMEMBERED) {
    surfaces.clear()
  }

  surfaces.set(key, surface)

  return surface
}
