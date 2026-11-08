import { type EyeSurface, flatten, type MaskPart, type Point, type Ring, sharedSurface } from './eye-surface'

export type Matrix = readonly [number, number, number, number, number, number]

export interface SurfaceSpec {
  frame: string
  mask: string[]
  reach: number
}

export interface Box {
  maxX: number
  maxY: number
  minX: number
  minY: number
}

export interface EyeSize {
  height: number
  width: number
}

export const FRAME_ATTRIBUTE = 'data-hb-frame'
export const MASK_ATTRIBUTE = 'data-hb-mask'
export const REACH_ATTRIBUTE = 'data-hb-reach'
export const SIZE_ATTRIBUTE = 'data-hb-size'

const IDENTITY: Matrix = [1, 0, 0, 1, 0, 0]
const TRANSFORM_CALL = /(\w+)\(([^)]*)\)/g
const KAPPA = 0.5522847498307936
const MASK_SEPARATOR = '|'
const DECIMALS = 3

export function multiply(m: Matrix, n: Matrix): Matrix {
  return [
    m[0] * n[0] + m[2] * n[1],
    m[1] * n[0] + m[3] * n[1],
    m[0] * n[2] + m[2] * n[3],
    m[1] * n[2] + m[3] * n[3],
    m[0] * n[4] + m[2] * n[5] + m[4],
    m[1] * n[4] + m[3] * n[5] + m[5]
  ]
}

export function invert([a, b, c, d, e, f]: Matrix): Matrix {
  const det = a * d - b * c

  return [d / det, -b / det, -c / det, a / det, (c * f - d * e) / det, (b * e - a * f) / det]
}

export function transformPoint(m: Matrix, [x, y]: Point): Point {
  return [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]]
}

export function translation(x: number, y: number): Matrix {
  return [1, 0, 0, 1, x, y]
}

function rotation(degrees: number, x = 0, y = 0): Matrix {
  const radians = (degrees * Math.PI) / 180
  const cos = Math.cos(radians)
  const sin = Math.sin(radians)

  return multiply(translation(x, y), multiply([cos, sin, -sin, cos, 0, 0], translation(-x, -y)))
}

function callMatrix(name: string, [first = 0, second, third]: number[]): Matrix {
  switch (name) {
    case 'translate':
      return translation(first, second ?? 0)

    case 'rotate':
      return rotation(first, second, third)

    case 'scale':
      return [first, 0, 0, second ?? first, 0, 0]

    default:
      return IDENTITY
  }
}

export function parseTransform(text: string): Matrix {
  let matrix = IDENTITY

  for (const [, name, args] of text.matchAll(TRANSFORM_CALL)) {
    const numbers = args
      .trim()
      .split(/[\s,]+/)
      .map(Number)

    matrix = multiply(matrix, name === 'matrix' ? (numbers as unknown as Matrix) : callMatrix(name, numbers))
  }

  return matrix
}

export function pillPath({ height, width }: EyeSize): string {
  const radius = Math.min(width, height) / 2
  const k = radius * KAPPA
  const halfX = width / 2
  const halfY = height / 2
  const nearX = halfX - radius
  const nearY = halfY - radius

  return (
    `M${halfX} ${-nearY}L${halfX} ${nearY}` +
    `C${halfX} ${nearY + k} ${nearX + k} ${halfY} ${nearX} ${halfY}L${-nearX} ${halfY}` +
    `C${-nearX - k} ${halfY} ${-halfX} ${nearY + k} ${-halfX} ${nearY}L${-halfX} ${-nearY}` +
    `C${-halfX} ${-nearY - k} ${-nearX - k} ${-halfY} ${-nearX} ${-halfY}L${nearX} ${-halfY}` +
    `C${nearX + k} ${-halfY} ${halfX} ${-nearY - k} ${halfX} ${-nearY}Z`
  )
}

export function circlePath(cx: number, cy: number, r: number): string {
  const k = r * KAPPA

  return (
    `M${cx + r} ${cy}C${cx + r} ${cy + k} ${cx + k} ${cy + r} ${cx} ${cy + r}` +
    `C${cx - k} ${cy + r} ${cx - r} ${cy + k} ${cx - r} ${cy}` +
    `C${cx - r} ${cy - k} ${cx - k} ${cy - r} ${cx} ${cy - r}` +
    `C${cx + k} ${cy - r} ${cx + r} ${cy - k} ${cx + r} ${cy}Z`
  )
}

export function surfaceAttributes(spec: SurfaceSpec): Record<string, string> {
  return {
    [FRAME_ATTRIBUTE]: spec.frame,
    [MASK_ATTRIBUTE]: spec.mask.join(MASK_SEPARATOR),
    [REACH_ATTRIBUTE]: String(spec.reach)
  }
}

export function readSurfaceSpec(element: Element): SurfaceSpec | null {
  const mask = element.getAttribute(MASK_ATTRIBUTE)
  const reach = Number(element.getAttribute(REACH_ATTRIBUTE) ?? 0)

  if (!mask || !Number.isFinite(reach)) {
    return null
  }

  return { frame: element.getAttribute(FRAME_ATTRIBUTE) ?? '', mask: mask.split(MASK_SEPARATOR), reach }
}

export function readEyeSize(element: Element): EyeSize | null {
  const [width, height] = (element.getAttribute(SIZE_ATTRIBUTE) ?? '').trim().split(/\s+/).map(Number)

  return width > 0 && height > 0 ? { height, width } : null
}

function surfaceKey({ frame, mask, reach }: SurfaceSpec): string {
  return [frame, reach, ...mask].join(MASK_SEPARATOR)
}

function surfaceOf(spec: SurfaceSpec, frame: Matrix) {
  const scale = Math.hypot(frame[0], frame[1])

  return sharedSurface(surfaceKey(spec), (): MaskPart[] =>
    spec.mask.map(d => ({
      reach: spec.reach * scale,
      rings: flatten(d).map(ring => ring.map(point => transformPoint(frame, point)))
    }))
  )
}

export function surfaceFor(spec: SurfaceSpec): EyeSurface {
  return surfaceOf(spec, parseTransform(spec.frame))
}

export function surfaceBounds(spec: SurfaceSpec): Box {
  const frame = parseTransform(spec.frame)
  const reach = spec.reach * Math.hypot(frame[0], frame[1])

  const points = spec.mask.flatMap(d => flatten(d).flatMap(ring => ring.map(point => transformPoint(frame, point))))

  return {
    maxX: Math.max(...points.map(([x]) => x)) + reach,
    maxY: Math.max(...points.map(([, y]) => y)) + reach,
    minX: Math.min(...points.map(([x]) => x)) - reach,
    minY: Math.min(...points.map(([, y]) => y)) - reach
  }
}

export function ringsPath(rings: Ring[], toLocal: Matrix): string {
  return rings
    .map(ring => {
      const points = ring.map(point => transformPoint(toLocal, point))

      return `M${points.map(([x, y]) => `${x.toFixed(DECIMALS)} ${y.toFixed(DECIMALS)}`).join('L')}Z`
    })
    .join('')
}

export function curveEye(spec: SurfaceSpec, size: EyeSize, eye: Matrix): string {
  const frame = parseTransform(spec.frame)
  const toFrame = multiply(frame, eye)
  const rings = flatten(pillPath(size)).map(ring => ring.map(point => transformPoint(toFrame, point)))

  return ringsPath(surfaceOf(spec, frame).project(rings, transformPoint(toFrame, [0, 0])), invert(toFrame))
}
