import { attributeText, eyeFillFor, isWhiteAvatarColor } from './avatar-color'
import { circlePath, curveEye, type EyeSize, parseTransform, surfaceAttributes, type SurfaceSpec } from './eye-frame'

const BLOB_PARTS = /^(<svg[^>]*>)<g fill="([^"]+)">(.*?)<\/g><g fill="([^"]+)">(.*?)<\/g>(.*)<\/svg>$/s

const FIGURE_TRANSFORM = 'rotate(-14 50 50) translate(50 50) scale(0.77) translate(-50 -50)'
const BODY_ROUNDING = 26
const PILL = { width: 10, height: 23, gap: 28, slant: -11, shiftX: 15, shiftY: -18, reach: 9 }
const PILL_SIZE: EyeSize = { height: PILL.height, width: PILL.width }
const PATH_DATA = /\sd="([^"]+)"/g
const NUMBER = /-?\d+(?:\.\d+)?/g

interface Box {
  maxX: number
  maxY: number
  minX: number
  minY: number
}

function pathBox(d: string): Box {
  const values = (d.match(NUMBER) ?? []).map(Number)
  const xs = values.filter((_, i) => i % 2 === 0)
  const ys = values.filter((_, i) => i % 2 === 1)

  return { minX: Math.min(...xs), maxX: Math.max(...xs), minY: Math.min(...ys), maxY: Math.max(...ys) }
}

function eyeBoxes(eyes: string): Box[] {
  return [...eyes.matchAll(PATH_DATA)].map(match => pathBox(match[1])).sort((a, b) => a.minX - b.minX)
}

type Point = [number, number]

const INSCRIBE_STEPS = 24
const INSCRIBE_MIN = 0.35

const PROBES: Point[] = [
  [-1, -0.6],
  [1, -0.6],
  [-1, 0.6],
  [1, 0.6],
  [0, -1],
  [0, 1],
  [-1, 0],
  [1, 0]
]

function insidePolygon([x, y]: Point, polygon: Point[]): boolean {
  let inside = false

  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    const [xi, yi] = polygon[i]
    const [xj, yj] = polygon[j]

    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) {
      inside = !inside
    }
  }

  return inside
}

export function inscribedBounds(polygon: Point[], reach: number): string {
  const xs = polygon.map(([x]) => x)
  const ys = polygon.map(([, y]) => y)
  const [minX, maxX, minY, maxY] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)]
  const cx = xs.reduce((sum, x) => sum + x, 0) / xs.length
  const cy = ys.reduce((sum, y) => sum + y, 0) / ys.length
  const halfW = Math.min(cx - minX, maxX - cx)
  const halfH = Math.min(cy - minY, maxY - cy)

  const fits = (scale: number) =>
    PROBES.every(([dx, dy]) => insidePolygon([cx + dx * halfW * scale, cy + dy * halfH * scale], polygon))

  let scale = 1

  for (let step = 0; step < INSCRIBE_STEPS && !fits(scale); step++) {
    scale = Math.max(INSCRIBE_MIN, scale - (1 - INSCRIBE_MIN) / INSCRIBE_STEPS)
  }

  return [
    cx - halfW * scale - reach,
    cy - halfH * scale - reach,
    cx + halfW * scale + reach,
    cy + halfH * scale + reach
  ]
    .map(value => value.toFixed(2))
    .join(' ')
}

const CIRCLE_INSET = 0.2
const CIRCLE = /<circle\s+cx="([^"]+)"\s+cy="([^"]+)"\s+r="([^"]+)"/g

function circleBounds(body: string): null | string {
  const circles = [...body.matchAll(CIRCLE)].map(match => ({
    cx: Number(match[1]),
    cy: Number(match[2]),
    r: Number(match[3])
  }))

  if (circles.length === 0 || circles.some(({ cx, cy, r }) => ![cx, cy, r].every(Number.isFinite))) {
    return null
  }

  const inset = CIRCLE_INSET * Math.max(...circles.map(({ r }) => r))
  const reach = BODY_ROUNDING / 2

  return [
    Math.min(...circles.map(({ cx, r }) => cx - r)) + inset - reach,
    Math.min(...circles.map(({ cy, r }) => cy - r)) - reach,
    Math.max(...circles.map(({ cx, r }) => cx + r)) - inset + reach,
    Math.max(...circles.map(({ cy, r }) => cy + r)) + reach
  ]
    .map(value => value.toFixed(2))
    .join(' ')
}

function bodyBounds(body: string): null | string {
  const fromCircles = circleBounds(body)

  if (fromCircles) {
    return fromCircles
  }

  const points = [...body.matchAll(PATH_DATA)].flatMap(match => {
    const values = (match[1].match(NUMBER) ?? []).map(Number)

    return values.flatMap((value, i): Point[] => (i % 2 === 0 && i + 1 < values.length ? [[value, values[i + 1]]] : []))
  })

  return points.length < 3 ? null : inscribedBounds(points, BODY_ROUNDING / 2)
}

function clamp(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value))
}

function pillCentre(x: number, y: number, box: Box): [number, number] {
  return [
    clamp(x, box.minX - PILL.reach, box.maxX + PILL.reach),
    clamp(y, box.minY - PILL.reach, box.maxY + PILL.reach)
  ]
}

function pill([x, y]: [number, number], side: 'l' | 'r', spec: SurfaceSpec) {
  const rest = `translate(${x} ${y}) rotate(${PILL.slant})`
  const d = curveEye(spec, PILL_SIZE, parseTransform(rest))

  return (
    `<g data-hb-eye="${side}" data-hb-rest="${rest}" data-hb-size="${PILL.width} ${PILL.height}" transform="${rest}">` +
    `<path d="${d}"/></g>`
  )
}

function pills(eyes: string, spec: SurfaceSpec): null | string {
  const [left, right] = eyeBoxes(eyes)

  if (!left || !right) {
    return null
  }

  const midX = (left.minX + left.maxX + right.minX + right.maxX) / 4 + PILL.shiftX
  const midY = (left.minY + left.maxY + right.minY + right.maxY) / 4 + PILL.shiftY

  return (
    pill(pillCentre(midX - PILL.gap / 2, midY, left), 'l', spec) +
    pill(pillCentre(midX + PILL.gap / 2, midY, right), 'r', spec)
  )
}

function maskOf(body: string): string[] {
  const circles = [...body.matchAll(CIRCLE)].map(match =>
    circlePath(Number(match[1]), Number(match[2]), Number(match[3]))
  )

  const paths = [...body.matchAll(PATH_DATA)].map(match => match[1])

  return [...circles, ...paths]
}

const CIRCLE_SAMPLES = 48

interface CircleBody {
  bounds: string
  markup: string
}

function circleBody(body: string): CircleBody | null {
  const values = [...body.matchAll(PATH_DATA)].flatMap(match => (match[1].match(NUMBER) ?? []).map(Number))
  const xs = values.filter((_, i) => i % 2 === 0)
  const ys = values.filter((_, i) => i % 2 === 1)

  if (xs.length < 3 || ys.length < 3 || values.some(value => !Number.isFinite(value))) {
    return null
  }

  const cx = (Math.min(...xs) + Math.max(...xs)) / 2
  const cy = (Math.min(...ys) + Math.max(...ys)) / 2
  const r = (Math.max(...xs) - Math.min(...xs) + Math.max(...ys) - Math.min(...ys)) / 4

  const outline = Array.from({ length: CIRCLE_SAMPLES }, (_, i): Point => {
    const angle = (i / CIRCLE_SAMPLES) * Math.PI * 2

    return [cx + r * Math.cos(angle), cy + r * Math.sin(angle)]
  })

  return {
    bounds: inscribedBounds(outline, BODY_ROUNDING / 2),
    markup: `<circle cx="${cx.toFixed(2)}" cy="${cy.toFixed(2)}" r="${r.toFixed(2)}"/>`
  }
}

function attributeList(attributes: Record<string, string>): string {
  return Object.entries(attributes)
    .map(([name, value]) => ` ${name}="${attributeText(value)}"`)
    .join('')
}

export function grokifyBlob(svg: string, options: { circle?: boolean } = {}): string {
  const parts = BLOB_PARTS.exec(svg)

  if (!parts) {
    return svg
  }

  const [, open, rawBodyFill, libraryBody, , eyes, rest] = parts
  const round = options.circle ? circleBody(libraryBody) : null
  const body = round?.markup ?? libraryBody
  const bounds = round?.bounds ?? bodyBounds(body)

  const spec: SurfaceSpec = { frame: FIGURE_TRANSFORM, mask: maskOf(body), reach: BODY_ROUNDING / 2 }
  const eyePills = pills(eyes, spec)

  if (!eyePills || !bounds) {
    return svg
  }

  const bodyFill = attributeText(rawBodyFill)
  const eyeFill = attributeText(eyeFillFor(rawBodyFill))

  const tone = isWhiteAvatarColor(rawBodyFill) ? ' data-hb-tone="white"' : ''

  return (
    `${open.replace(/>$/, `${tone}>`)}<g transform="${FIGURE_TRANSFORM}">` +
    `<g data-hb-body="" fill="${bodyFill}" stroke="${bodyFill}" stroke-width="${BODY_ROUNDING}" stroke-linejoin="round">${body}</g>` +
    `<g data-hb-eyes="" fill="${eyeFill}"><g data-hb-gaze="" data-hb-bounds="${attributeText(bounds)}"${attributeList(surfaceAttributes(spec))}><g data-hb-lids="">${eyePills}</g></g></g></g>${rest}</svg>`
  )
}
