/**
 * Bot avatars: the shape/color/eyes vocabulary, the deterministic blobatar
 * faces, the shared face clock that animates them, and `BotFace` — the one
 * component every roster row, dialog and tile renders a bot with.
 *
 * Render-only. The editor UI that picks these lives in `avatar-picker.tsx`.
 */

import * as sdk from '@hermes/plugin-sdk'
import { profileColor } from '@hermes/plugin-sdk'
import type { CSSProperties } from 'react'

import { attributeText, eyeFillFor, isWhiteAvatarColor, safeAvatarColor } from './avatar-color'
import { asMotionMood, workingDots } from './avatar-motion'
import { paintMotion } from './avatar-paint'
import { extendBlob, isExtendedBlobKind } from './blob-extended'
import { grokifyBlob, inscribedBounds } from './blob-style'
import { curveEye, type EyeSize, parseTransform, surfaceAttributes, type SurfaceSpec } from './eye-frame'
import { eyesDriven, prefersReducedMotion } from './face-driver'
import type { AvatarAppearance, AvatarShape, BotMeta, FaceMood } from './types'

// Deterministic blob avatars (name → face). Feature-detected: older SDKs
// without the export fall back to the legacy math-face shapes below.
export const blobatarSvg = typeof sdk === 'undefined' ? undefined : sdk.blobatarSvg

const blobatarSilhouette =
  typeof sdk === 'undefined' || !('blobatarSilhouette' in sdk) ? undefined : sdk.blobatarSilhouette

// Budgeted render loop (fps cap + observability pause + dormancy + teardown).
// Feature-detected: older desktops fall back to the hand-rolled clock below.
const createBudgetedLoop = typeof sdk === 'undefined' ? undefined : sdk.createBudgetedLoop

// ── avatars (shape + color + eyes) ──────────────────────────────────────────

// The original flat shapes. Sigils ('sigil-N') and platonic
// solids remain render-only so any bot that picked one during the experiments
// keeps its look.
const AVATAR_SHAPES: AvatarShape[] = ['circle', 'squircle', 'pill', 'triangle', 'hexagon', 'cloud', 'drop']
export const AVATAR_PICKER_SHAPES = ['circle', 'blob', 'squircle', 'pill', 'triangle', 'hexagon', 'cloud', 'drop']

/** xorshift PRNG seeded from a string — stable across sessions/platforms. */
function sigilRng(text: string) {
  let h = 2166136261

  for (const ch of text) {
    h ^= ch.charCodeAt(0)
    h = Math.imul(h, 16777619)
  }

  let state = h >>> 0 || 88675123

  return () => {
    state ^= state << 13
    state ^= state >>> 17
    state ^= state << 5
    state >>>= 0

    return state / 4294967296
  }
}

interface SigilGeometry {
  /** The optional diamond ring, as an SVG path. */
  ring: null | string
  /** Every stroke joined into one SVG path. */
  strokes: string
}

const SIGIL_DIAMOND = 'M20 4 L36 20 L20 36 L4 20 Z'
const SIGIL_EYE: EyeSize = { height: 4.8, width: 4.8 }
const SIGIL_SURFACE: SurfaceSpec = { frame: '', mask: [SIGIL_DIAMOND], reach: 0 }
const SIGIL_TRAVEL = 20

/**
 * Angular hermetic sigil: strokes on the left half of a 5-column grid,
 * mirrored right, plus a chance of a diamond ring. Returns SVG path strings.
 */
function sigilGeometry(name: string, seed: number): SigilGeometry {
  const rng = sigilRng(`${name}::${seed}`)
  const gx = (i: number) => 6 + i * 7 // 5 cols: 6..34
  const gy = (j: number) => 8 + j * 6 // 5 rows: 8..32
  const strokes: string[] = []
  const segments = 4 + Math.floor(rng() * 3)

  for (let k = 0; k < segments; k++) {
    const x1 = Math.floor(rng() * 3) // left half incl. center
    const y1 = Math.floor(rng() * 5)
    const x2 = Math.min(2, Math.max(0, x1 + (rng() > 0.5 ? 1 : -1)))
    const y2 = Math.min(4, Math.max(0, y1 + Math.floor(rng() * 3) - 1))
    strokes.push(`M${gx(x1)} ${gy(y1)} L${gx(x2)} ${gy(y2)}`)
    // mirror (col i → col 4-i)
    strokes.push(`M${gx(4 - x1)} ${gy(y1)} L${gx(4 - x2)} ${gy(y2)}`)

    // occasional cross-tie through the axis for connectedness
    if (rng() > 0.6) {
      strokes.push(`M${gx(x2)} ${gy(y2)} L${gx(4 - x2)} ${gy(y2)}`)
    }
  }

  // spine down the axis grounds every variant
  strokes.push(`M20 ${gy(0)} L20 ${gy(4)}`)
  const ring = rng() > 0.45 ? SIGIL_DIAMOND : null

  return {
    strokes: strokes.join(' '),
    ring
  }
}

export function defaultShapeFor(name: string): AvatarShape {
  let hash = 0

  for (const ch of name) {
    hash = (hash * 31 + ch.charCodeAt(0)) >>> 0
  }

  return AVATAR_SHAPES[hash % AVATAR_SHAPES.length]
}

// ── blobatar shapes mode (default for new agents) ───────────────────────────
// Deterministic soft-body faces drawn from a string. Shape strings:
//   'blobatar'                — the face follows the bot's NAME (renaming the
//                               bot re-rolls the face, live in the dialog)
//   'blobatar:<seed>'         — seed locked (the 🔒 lock / 🎲 randomize picks)
//   'blobatar:<seed>:<kind>'  — plus one of the fourteen silhouettes pinned
//   'blobatar::<kind>'        — silhouette pinned, seed still follows the name
// Bot names are slugs (NAME_RE) and generated seeds are base36, so ':' never
// appears inside a segment. Colors come from the library's own name-derived
// palette (contrast-guaranteed) — the classic color swatches don't apply.

export const BLOB_KINDS = [
  'round',
  'organic',
  'boxy',
  'capsule',
  'nub',
  'cloud',
  'droplet',
  'hexagon',
  'sun',
  'triangle',
  'spark',
  'clover',
  'burst',
  'gem'
]

// Trait positions at the center of each silhouette band. Band thresholds are
// frozen per blobatar major (gen2: 0.22 / 0.48 / 0.60 / 0.70 / 0.79 / 0.86 /
// 0.915 / 0.95 / 0.98).
// Keyed by BlobKind, but indexed with the free-form segment parseBlobShape
// pulls out of a stored shape string, which no guard here can narrow.
const BLOB_KIND_TRAIT: Record<string, number> = {
  round: 0.11,
  organic: 0.35,
  boxy: 0.54,
  capsule: 0.65,
  nub: 0.745,
  cloud: 0.825,
  droplet: 0.8875,
  hexagon: 0.9325,
  sun: 0.965,
  triangle: 0.99,
  spark: 0.11,
  clover: 0.11,
  burst: 0.11,
  gem: 0.11
}

export function isBlobShape(shape: null | string | undefined) {
  return shape === 'blobatar' || (typeof shape === 'string' && shape.startsWith('blobatar:'))
}

interface ParsedBlobShape {
  /** A BlobKind when the silhouette is pinned, else empty. */
  kind: string
  /** The seed actually rendered — the pinned one, else the bot's name. */
  seed: string
  /** The pinned seed alone, empty when the face follows the name. */
  seedPart: string
}

export function parseBlobShape(shape: null | string | undefined, name: string | undefined): ParsedBlobShape {
  const parts = typeof shape === 'string' ? shape.split(':') : []
  const seedPart = parts[1] || ''
  const kind = BLOB_KINDS.includes(parts[2]) ? parts[2] : ''

  return {
    seed: seedPart || name || 'agent',
    seedPart,
    kind
  }
}

export function blobShapeString(seedPart: string, kind: string) {
  if (kind) {
    return `blobatar:${seedPart}:${kind}`
  }

  return seedPart ? `blobatar:${seedPart}` : 'blobatar'
}

const BLINK_SPREAD_SECONDS = 4

function blinkDelaySeconds(name: string): number {
  let hash = 0

  for (const char of name) {
    hash = (hash * 31 + char.charCodeAt(0)) >>> 0
  }

  return ((hash % 1000) / 1000) * BLINK_SPREAD_SECONDS
}

function blinkDelayValue(name: string): string {
  return `${blinkDelaySeconds(name).toFixed(2)}s`
}

function blinkStyle(name: string) {
  return { '--hb-blink-delay': blinkDelayValue(name) } as CSSProperties
}

function faceTone(color: string): 'white' | undefined {
  return isWhiteAvatarColor(color) ? 'white' : undefined
}

function syncFaceMood(host: HTMLElement | null, mood: string) {
  host?.firstElementChild?.setAttribute('data-hb-mood', mood)
}

/** Static SVG markup for a blob face, tagged data-bot-face so the roster's
 *  PNG backfill (pushLocalAvatars → rasterizeSvgToPng) still finds it. */
function blobMarkup(shape: null | string | undefined, name: string, size: number, color?: string) {
  if (!blobatarSvg) {
    return null
  }

  const { seed, kind } = parseBlobShape(shape, name)

  const opts: { palette?: { eye: string; head: string }; size: number; traits?: Record<string, number> } = {
    size
  }

  const safeColor = safeAvatarColor(color)

  if (safeColor && safeColor !== profileColor(name)) {
    opts.palette = { head: safeColor, eye: eyeFillFor(safeColor) }
  }

  if (kind) {
    opts.traits = {
      shape: BLOB_KIND_TRAIT[kind]
    }
  }

  const circle = (kind || blobatarSilhouette?.(seed, opts.traits)) === 'round'

  try {
    // The name goes in as escaped text, through a replacer so `$&`-style patterns in it stay literal.
    const library = blobatarSvg(seed, opts)

    return grokifyBlob(isExtendedBlobKind(kind) ? extendBlob(library, kind) : library, { circle }).replace(
      '<svg ',
      () =>
        `<svg data-bot-face="${attributeText(name)}" data-bot-gaze="eyes" data-hb-key="${attributeText(seed)}" ` +
        `style="--hb-blink-delay:${blinkDelayValue(name)}" `
    )
  } catch {
    return null
  }
}

/** The SVG presentation props shapeNode spreads onto a <path>. Named so the
 *  literal join/cap values keep their literal types instead of widening. */
interface FacePathProps {
  fill: string
  stroke: string
  strokeLinecap?: 'round'
  strokeLinejoin: 'round'
  strokeWidth: number
}

/** The colored body of the avatar (no eyes). Platonic solids are a filled
 *  silhouette + translucent internal edge lines (the projected wireframe);
 *  legacy flat shapes keep their old geometry so stored picks still render. */
function shapeNode(shape: string, color: string, botName = 'agent') {
  if (shape.startsWith('sigil-')) {
    const seed = Number(shape.slice(6)) || 0
    const { strokes, ring } = sigilGeometry(botName, seed)

    const sw: FacePathProps = {
      fill: 'none',
      stroke: color,
      strokeWidth: 2.2,
      strokeLinecap: 'round',
      strokeLinejoin: 'round'
    }

    return (
      <g data-hb-body="">
        {ring ? <path d={ring} fill="none" opacity={0.5} stroke={color} strokeWidth={1.2} /> : null}
        <path d={strokes} {...sw} />
      </g>
    )
  }

  const stroke: FacePathProps = {
    fill: color,
    stroke: color,
    strokeWidth: 7,
    strokeLinejoin: 'round'
  }

  const edge: FacePathProps = {
    fill: 'none',
    stroke: 'rgba(0,0,0,0.4)',
    strokeWidth: 1.4,
    strokeLinejoin: 'round',
    strokeLinecap: 'round'
  }

  const face: FacePathProps = {
    fill: color,
    stroke: 'rgba(0,0,0,0.4)',
    strokeWidth: 1.4,
    strokeLinejoin: 'round'
  }

  switch (shape) {
    // ── platonic solids ──
    case 'tetrahedron':
      return (
        <g>
          <path d="M20 5 L36 33 L4 33 Z" {...face} />
          <path d="M20 5 L20 25 M4 33 L20 25 M36 33 L20 25" {...edge} />
        </g>
      )

    case 'cube':
      return (
        <g>
          <path d="M20 4 L33 11 L33 29 L20 36 L7 29 L7 11 Z" {...face} />
          <path d="M7 11 L20 18 L33 11 M20 18 L20 36" {...edge} />
        </g>
      )

    case 'octahedron':
      return (
        <g>
          <path d="M20 3 L36 20 L20 37 L4 20 Z" {...face} />
          <path d="M4 20 L36 20 M20 3 L20 37" {...edge} />
        </g>
      )

    case 'dodecahedron':
      return (
        <g>
          <path
            d="M20 3 L30 6.2 L36.2 14.7 L36.2 25.3 L30 33.8 L20 37 L10 33.8 L3.8 25.3 L3.8 14.7 L10 6.2 Z"
            {...face}
          />
          <path
            d={
              'M20 12 L27.6 17.5 L24.7 26.5 L15.3 26.5 L12.4 17.5 Z ' +
              'M20 12 L20 3 M27.6 17.5 L36.2 14.7 M24.7 26.5 L30 33.8 M15.3 26.5 L10 33.8 M12.4 17.5 L3.8 14.7'
            }
            {...edge}
          />
        </g>
      )

    case 'icosahedron':
      return (
        <g>
          <path d="M20 3 L34.7 11.5 L34.7 28.5 L20 37 L5.3 28.5 L5.3 11.5 Z" {...face} />
          <path
            d={
              'M20 11 L27.8 24.5 L12.2 24.5 Z ' +
              'M20 11 L20 3 M20 11 L34.7 11.5 M20 11 L5.3 11.5 ' +
              'M27.8 24.5 L34.7 11.5 M27.8 24.5 L34.7 28.5 M27.8 24.5 L20 37 ' +
              'M12.2 24.5 L5.3 11.5 M12.2 24.5 L5.3 28.5 M12.2 24.5 L20 37'
            }
            {...edge}
          />
        </g>
      )

    // ── legacy flat shapes (stored picks from earlier versions) ──
    case 'squircle':
      return <rect fill={color} height={34} rx={11} width={34} x={3} y={3} />

    case 'pill':
      return <rect fill={color} height={26} rx={13} width={36} x={2} y={7} />

    case 'triangle':
      return <path d="M20 5.5 L36 33.5 L4 33.5 Z" {...stroke} />

    case 'hexagon':
      return <path d="M20 3.5 L34.5 11.75 L34.5 28.25 L20 36.5 L5.5 28.25 L5.5 11.75 Z" {...stroke} />

    case 'cloud':
      return <path d="M11 32 a7.5 7.5 0 0 1 -1 -14.9 A9.5 9.5 0 0 1 29 12.5 A7 7 0 0 1 30 32 Z" fill={color} />

    case 'drop':
      return <path d="M20 3 C20 3 6 20 6 27 a14 13.5 0 0 0 28 0 C34 20 20 3 20 3 Z" fill={color} />

    default:
      return <circle cx={20} cy={20} fill={color} r={17.5} />
  }
}

/** One point in the 40x40 face box. */
type FacePoint = [number, number]

function cubicAt(p0: FacePoint, p1: FacePoint, p2: FacePoint, p3: FacePoint, t: number): FacePoint {
  const u = 1 - t

  return [
    u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
    u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1]
  ]
}

/** Same outline as the old GitHub drop path, so it stays a fat water drop. */
function sampleDropRing(steps: number): FacePoint[] {
  const pts: FacePoint[] = []
  const n = Math.max(8, Math.floor(steps / 3))

  for (let i = 0; i < n; i++) {
    pts.push(cubicAt([20, 3], [20, 3], [6, 20], [6, 27], i / n))
  }

  for (let i = 0; i <= n; i++) {
    const t = (i / n) * Math.PI
    pts.push([20 - 14 * Math.cos(t), 27 + 13.5 * Math.sin(t)])
  }

  for (let i = 1; i <= n; i++) {
    pts.push(cubicAt([34, 27], [34, 20], [20, 3], [20, 3], i / n))
  }

  return pts
}

/** A center-parameterized elliptical arc, as sampleArc walks it. */
interface FaceArc {
  cx: number
  cy: number
  dtheta: number
  rx: number
  ry: number
  theta1: number
}

function svgArc(
  x1: number,
  y1: number,
  rx: number,
  ry: number,
  fa: number,
  fs: number,
  x2: number,
  y2: number
): FaceArc {
  const dx = (x1 - x2) / 2
  const dy = (y1 - y2) / 2
  let rx2 = rx * rx
  let ry2 = ry * ry
  const lam = (dx * dx) / rx2 + (dy * dy) / ry2

  if (lam > 1) {
    const s = Math.sqrt(lam)
    rx *= s
    ry *= s
    rx2 = rx * rx
    ry2 = ry * ry
  }

  const num = rx2 * ry2 - rx2 * dy * dy - ry2 * dx * dx
  const den = rx2 * dy * dy + ry2 * dx * dx
  let sq = Math.sqrt(Math.max(0, num / den))

  if (fa === fs) {
    sq = -sq
  }

  const cx = sq * ((rx * dy) / ry) + (x1 + x2) / 2
  const cy = sq * ((-ry * dx) / rx) + (y1 + y2) / 2

  const ang = (ux: number, uy: number, vx: number, vy: number) => {
    const n = Math.hypot(ux, uy) * Math.hypot(vx, vy) || 1
    let a = Math.acos(Math.max(-1, Math.min(1, (ux * vx + uy * vy) / n)))

    if (ux * vy - uy * vx < 0) {
      a = -a
    }

    return a
  }

  const theta1 = ang(1, 0, (x1 - cx) / rx, (y1 - cy) / ry)
  let dtheta = ang((x1 - cx) / rx, (y1 - cy) / ry, (x2 - cx) / rx, (y2 - cy) / ry)

  if (!fs && dtheta > 0) {
    dtheta -= Math.PI * 2
  }

  if (fs && dtheta < 0) {
    dtheta += Math.PI * 2
  }

  return {
    cx,
    cy,
    rx,
    ry,
    theta1,
    dtheta
  }
}

function sampleArc(arc: FaceArc, n: number): FacePoint[] {
  const pts: FacePoint[] = []

  for (let i = 0; i < n; i++) {
    const th = arc.theta1 + arc.dtheta * (i / n)
    pts.push([arc.cx + arc.rx * Math.cos(th), arc.cy + arc.ry * Math.sin(th)])
  }

  return pts
}

/** Same outline as the old GitHub cloud path: three puffs and a flat floor. */
function sampleCloudRing(steps: number): FacePoint[] {
  const a1 = svgArc(11, 32, 7.5, 7.5, 0, 1, 10, 17.1)
  const a2 = svgArc(10, 17.1, 9.5, 9.5, 0, 1, 29, 12.5)
  const a3 = svgArc(29, 12.5, 7, 7, 0, 1, 30, 32)
  const len1 = Math.abs(a1.dtheta) * a1.rx
  const len2 = Math.abs(a2.dtheta) * a2.rx
  const len3 = Math.abs(a3.dtheta) * a3.rx
  const len4 = 19
  const total = len1 + len2 + len3 + len4
  const n = Math.max(64, steps)
  const n1 = Math.max(8, Math.round((n * len1) / total))
  const n2 = Math.max(10, Math.round((n * len2) / total))
  const n3 = Math.max(10, Math.round((n * len3) / total))
  const n4 = Math.max(4, n - n1 - n2 - n3)
  const pts: FacePoint[] = []
  pts.push(...sampleArc(a1, n1))
  pts.push(...sampleArc(a2, n2))
  pts.push(...sampleArc(a3, n3))

  for (let i = 0; i < n4; i++) {
    pts.push([30 + (11 - 30) * (i / n4), 32])
  }

  return pts
}

/** Outline of a face in a 40x40 box. Same family as Grok Bot
 *  (blob / squircle / pebble / \u2026) but sampled from formulas, not
 *  a dumped point cloud. */
function sampleFaceRing(shape: null | string | undefined, steps = 52): FacePoint[] {
  const kind = (shape || '').startsWith('sigil-') ? 'circle' : shape

  if (kind === 'drop' || kind === 'teardrop') {
    return sampleDropRing(steps)
  }

  if (kind === 'cloud') {
    return sampleCloudRing(steps)
  }

  const pts: FacePoint[] = []

  for (let i = 0; i < steps; i++) {
    const a = (i / steps) * Math.PI * 2 - Math.PI / 2
    const c = Math.cos(a)
    const s = Math.sin(a)
    let rx = 16
    let ry = 16

    if (kind === 'circle') {
      rx = ry = 16.2
    } else if (kind === 'blob') {
      rx = ry = 16 + 1.7 * Math.sin(3 * a) + 0.7 * Math.cos(5 * a)
    } else if (kind === 'squircle') {
      const p = 5
      const d = Math.pow(Math.abs(c) ** p + Math.abs(s) ** p, 1 / p) || 1
      rx = ry = 16.2 / d
    } else if (kind === 'pill') {
      const d = Math.pow(Math.abs(c) ** 8 + Math.abs(s / 0.72) ** 8, 1 / 8) || 1
      rx = ry = 16 / d
    } else if (kind === 'triangle' || kind === 'tetrahedron' || kind === 'wedge') {
      const u = (a + Math.PI / 2 + Math.PI * 2) % (Math.PI * 2)
      const sector = (u / ((Math.PI * 2) / 3)) % 1
      rx = ry = 13.5 / Math.max(0.42, Math.cos((sector - 0.5) * 1.9))
    } else if (kind === 'hexagon' || kind === 'hex' || kind === 'icosahedron' || kind === 'dodecahedron') {
      const seg = Math.PI / 3
      const hex = Math.cos(seg / 2) / Math.cos(a - seg * Math.round(a / seg))
      rx = ry = 16.2 * hex
    } else if (kind === 'cube' || kind === 'octahedron') {
      const p = 3.1
      const d = Math.pow(Math.abs(c) ** p + Math.abs(s) ** p, 1 / p) || 1
      rx = ry = 16 / d
    } else if (kind === 'pebble') {
      rx = 16.4 * (1.04 - 0.14 * Math.cos(2 * a))
      ry = 15.2 * (1.06 + 0.08 * Math.sin(2 * a))
    } else {
      rx = ry = 16.2
    }

    pts.push([20 + rx * c, 20 + ry * s])
  }

  return pts
}

function projectFacePoint(x: number, y: number, turn: number, tilt: number, roll: number): FacePoint {
  const dx = x - 20
  const dy = y - 20
  const r = (roll * Math.PI) / 180
  const xr = dx * Math.cos(r) - dy * Math.sin(r)
  const yr = dx * Math.sin(r) + dy * Math.cos(r)
  const sx = 0.74 + 0.26 * Math.abs(Math.cos((turn * Math.PI) / 180))
  const sy = 0.8 + 0.2 * Math.abs(Math.cos((tilt * Math.PI) / 180))

  return [20 + xr * sx, 20 + yr * sy]
}

function ringToPath(pts: FacePoint[]) {
  if (!pts.length) {
    return ''
  }

  let d = `M${pts[0][0].toFixed(2)} ${pts[0][1].toFixed(2)}`

  for (let i = 1; i < pts.length; i++) {
    d += `L${pts[i][0].toFixed(2)} ${pts[i][1].toFixed(2)}`
  }

  return d + 'Z'
}

/** One frame of the idle face: a barely-there head sway. Working moods are
 *  owned by the loading clips (`avatar-paint.ts`). */
interface FacePose {
  roll: number
  tilt: number
  turn: number
}

function idlePose(t: number): FacePose {
  return {
    turn: Math.sin(t * 0.5) * 1.5,
    tilt: Math.sin(t * 0.27),
    roll: Math.sin(t * 0.85) * 1.2
  }
}

const MATH_FIGURE_TRANSFORM = 'rotate(-14 20 20) translate(20 22) scale(0.72) translate(-20 -22)'
const MATH_EYE = { width: 4.8, height: 11.4, gap: 9.4, slant: -11, midX: 23.4, shiftY: -1.6 }
const MATH_EYE_SIZE: EyeSize = { height: MATH_EYE.height, width: MATH_EYE.width }
const MATH_CLOUD_PATH = 'M11 32 a7.5 7.5 0 0 1 -1 -14.9 A9.5 9.5 0 0 1 29 12.5 A7 7 0 0 1 30 32 Z'

function mathEyeLine(shape: string) {
  return (shape === 'cloud' ? 22 : 17.2) + MATH_EYE.shiftY
}

const MATH_STROKE_REACH = 6.5
const MATH_CLOUD_BOUNDS = '3 5 37 38'

function mathBounds(shape: string, ring: FacePoint[]): string {
  if (shape === 'cloud') {
    return MATH_CLOUD_BOUNDS
  }

  return inscribedBounds(ring, MATH_STROKE_REACH)
}

function paintMathFace(svg: SVGSVGElement, t: number) {
  const shape = svg.getAttribute('data-hb-shape') || 'circle'
  const pose = idlePose(t)
  const body = svg.querySelector('[data-hb-body]')

  if (body) {
    if (shape === 'cloud') {
      body.setAttribute('d', MATH_CLOUD_PATH)
    } else {
      const ring = sampleFaceRing(shape).map(([x, y]) => projectFacePoint(x, y, pose.turn, pose.tilt, pose.roll))
      body.setAttribute('d', ringToPath(ring))
    }
  }

  svg.style.transform = `rotate(${pose.tilt}deg)`
  svg.style.transformOrigin = '50% 70%'
}

const FACE_SELECTOR = 'svg[data-hb-math], svg[data-bot-face]'
const IDLE_FRAME_MS = 1000 / 15
const EVERY_FRAME_FPS = 1000

function animates(face: Element): boolean {
  return face.hasAttribute('data-hb-math') || eyesDriven(face)
}

function walkFaces(root: Document | ShadowRoot | null, acc: SVGSVGElement[]): SVGSVGElement[] {
  if (!root || !root.querySelectorAll) {
    return acc
  }

  root.querySelectorAll<SVGSVGElement>(FACE_SELECTOR).forEach(node => acc.push(node))
  root.querySelectorAll('*').forEach(el => {
    if (el.shadowRoot) {
      walkFaces(el.shadowRoot, acc)
    }
  })

  return acc
}

/** The single shared face clock, parked on `window` so a second plugin load
 *  adopts the running one instead of starting a rival rAF loop. */
interface FaceClock {
  stop: () => void
  wake: () => void
}

declare global {
  interface Window {
    __hbFaceClock?: FaceClock
  }
}

export function startFaceClock() {
  if (typeof window === 'undefined') {
    return
  }

  if (window.__hbFaceClock) {
    // Already initialized (possibly parked) — make sure it's awake. BotFace
    // renders route here, so a face mounting is what wakes a dormant clock.
    window.__hbFaceClock.wake()

    return
  }

  const t0 = performance.now()
  // A large roster can mount hundreds of faces. Observe the cached nodes so
  // off-screen cards do not consume a full animation frame by themselves.
  let faces: SVGSVGElement[] = []
  let lastScan = -Infinity
  let lastIdlePaint = -Infinity
  // Fed from IntersectionObserver entries, whose `target` is a plain Element.
  const visibleFaces = new Set<Element>()
  const observedFaces = new Set<SVGSVGElement>()

  const observer =
    typeof IntersectionObserver === 'function'
      ? new IntersectionObserver(entries => {
          let becameVisible = false

          for (const entry of entries) {
            if (entry.isIntersecting) {
              visibleFaces.add(entry.target)
              becameVisible = true
            } else {
              visibleFaces.delete(entry.target)
            }
          }

          // A parked clock (no visible faces) resumes when one scrolls in.
          if (becameVisible) {
            window.__hbFaceClock?.wake()
          }
        })
      : null

  const scanFaces = () => {
    faces = walkFaces(document, [])

    if (!observer) {
      return
    }

    const currentFaces = new Set(faces)

    for (const svg of observedFaces) {
      if (!currentFaces.has(svg)) {
        observer.unobserve(svg)
        observedFaces.delete(svg)
        visibleFaces.delete(svg)
      }
    }

    for (const svg of faces) {
      if (!observedFaces.has(svg)) {
        observedFaces.add(svg)
        observer.observe(svg)
      }
    }
  }

  // Shared painting body for both scheduling paths: 1Hz document rescans,
  // paint only visible faces (all cached faces when IO is unavailable).
  const paint = (now: number) => {
    if (now - lastScan > 1000) {
      scanFaces()
      lastScan = now
    }

    const t = (now - t0) / 1000
    const epochMs = Date.now()
    const reduceMotion = prefersReducedMotion()
    const idleDue = now - lastIdlePaint >= IDLE_FRAME_MS
    const facesToPaint = observer ? visibleFaces : faces

    if (idleDue) {
      lastIdlePaint = now
    }

    for (const svg of facesToPaint) {
      if (svg.isConnected) {
        // Both caches only ever hold nodes matched by FACE_SELECTOR.
        const face = svg as SVGSVGElement

        if (!paintMotion(face, now, epochMs, reduceMotion) && idleDue && face.hasAttribute('data-hb-math')) {
          paintMathFace(face, t)
        }
      }
    }
  }

  // Nothing worth animating: no faces mounted (BotFace wakes us on the next
  // mount), none visible (the observer wakes us when one scrolls in), or only
  // static ones (a mood change re-renders the BotFace, which wakes us).
  const idle = () => !Array.from(observer ? visibleFaces : faces).some(face => animates(face))

  const teardownCaches = () => {
    if (observer) {
      observer.disconnect()
    }

    visibleFaces.clear()
    observedFaces.clear()
    faces = []
    delete window.__hbFaceClock
  }

  // Newer desktops: the SDK's budgeted loop owns scheduling (frame budget,
  // hidden/minimized/unfocused pause, dormancy, teardown). typeof-guarded so
  // older shells and the vm test harness use the hand-rolled path below.
  if (typeof createBudgetedLoop === 'function' && createBudgetedLoop) {
    const loop = createBudgetedLoop(paint, {
      fps: EVERY_FRAME_FPS,
      idleWhen: idle
    })

    window.__hbFaceClock = {
      stop: () => {
        loop.dispose()
        teardownCaches()
      },
      wake: () => {
        // Faces may have mounted/unmounted while parked — rescan on wake.
        lastScan = -Infinity
        loop.wake()
      }
    }

    return
  }

  // Fallback scheduling for desktops whose SDK predates createBudgetedLoop.
  let rafId = 0
  let dormant = false
  let stopped = false

  const tick = (now: number) => {
    if (stopped) {
      return
    }

    rafId = 0

    // The clock still uses rAF so Chromium can pause it when the window is occluded.
    if (!document.hidden) {
      paint(now)
    }

    // Park instead of burning frames + 1Hz whole-document shadow walks.
    if (idle()) {
      dormant = true

      return
    }

    rafId = window.requestAnimationFrame(tick)
  }

  const wake = () => {
    if (stopped || !dormant) {
      return
    }

    dormant = false
    // Faces may have mounted/unmounted while parked — rescan on first tick.
    lastScan = -Infinity
    rafId = window.requestAnimationFrame(tick)
  }

  const stop = () => {
    stopped = true

    if (rafId) {
      window.cancelAnimationFrame(rafId)
      rafId = 0
    }

    teardownCaches()
  }

  window.__hbFaceClock = {
    stop,
    wake
  }
  rafId = window.requestAnimationFrame(tick)
}

/** Tear the face clock down (plugin disable/reload) — cancels the animation
 *  frame, disconnects the visibility observer, and drops all cached nodes. */
export function stopFaceClock() {
  if (typeof window !== 'undefined' && window.__hbFaceClock) {
    window.__hbFaceClock.stop()
  }
}

interface BotFaceProps {
  color: string
  image?: null | string
  mood?: FaceMood
  name?: string
  /** Free-form appearance string, not just AvatarShape: also `sigil-<n>`,
   *  a platonic solid, or `blobatar[:seed[:kind]]`. */
  shape: string
  size?: number
}

/**
 * Live math face. Photos still use <img>. Shape avatars stay SVG so
 * the clock can move them (a baked PNG cannot).
 */
export function BotFace({ shape, color: rawColor, image, size = 36, name = 'agent', mood = 'idle' }: BotFaceProps) {
  startFaceClock()

  const color = avatarColor(rawColor, name)

  if (image) {
    return (
      <img
        alt=""
        aria-hidden
        src={image}
        style={{
          width: size,
          height: size,
          borderRadius: '22%',
          objectFit: 'cover',
          display: 'block'
        }}
      />
    )
  }

  // Blobatar shapes: the library draws the whole face (body + eyes + its own
  // name-derived palette). Inline SVG via innerHTML so the roster PNG
  // backfill's `svg[data-bot-face=…]` query still finds it; the math clock
  // ignores it (no data-hb-math). Falls back to the legacy math face when the
  // SDK predates the export.
  if (isBlobShape(shape)) {
    const markup = blobMarkup(shape, name, size, color)

    if (markup) {
      return (
        <span
          aria-hidden
          dangerouslySetInnerHTML={{
            __html: markup
          }}
          ref={host => syncFaceMood(host, mood)}
          style={{
            width: size,
            height: size,
            display: 'block',
            lineHeight: 0
          }}
        />
      )
    }

    // Older SDK without blobatar: legacy deterministic shape from the name.
    shape = defaultShapeFor(name)
  }

  // Sigils are line art (no filled body) — the math clock rebuilds filled
  // outlines, which would turn a stored sigil pick into a blank circle.
  // Keep the legacy static render for them so old picks still draw.
  if (shape.startsWith('sigil-')) {
    const eyes = (
      <g data-hb-facing="rest" data-hb-gaze="" data-hb-travel={SIGIL_TRAVEL} {...surfaceAttributes(SIGIL_SURFACE)}>
        {(['l', 'r'] as const).map((side, index) => {
          const rest = `translate(${index === 0 ? 16 : 24} 14)`

          return (
            <g
              data-hb-eye={side}
              data-hb-rest={rest}
              data-hb-size={`${SIGIL_EYE.width} ${SIGIL_EYE.height}`}
              key={side}
              transform={rest}
            >
              <path d={curveEye(SIGIL_SURFACE, SIGIL_EYE, parseTransform(rest))} fill={color} />
            </g>
          )
        })}
      </g>
    )

    return (
      <svg
        aria-hidden
        className="overflow-visible"
        data-bot-face={name}
        data-hb-key={name}
        data-hb-mood={mood}
        data-hb-sigil="1"
        data-hb-tone={faceTone(color)}
        height={size}
        viewBox="0 0 40 40"
        width={size}
      >
        {shapeNode(shape, color, name)}
        {eyes}
      </svg>
    )
  }

  const ring = sampleFaceRing(shape)
  const bodyPath = shape === 'cloud' ? MATH_CLOUD_PATH : ringToPath(ring)
  const surface: SurfaceSpec = { frame: MATH_FIGURE_TRANSFORM, mask: [bodyPath], reach: MATH_STROKE_REACH }
  const restDots = workingDots(asMotionMood(mood), 0)
  const eyeY0 = mathEyeLine(shape)
  const mathEyeRest = (cx: number) => `translate(${cx} ${eyeY0}) rotate(${MATH_EYE.slant})`
  const eyeLeft = MATH_EYE.midX - MATH_EYE.gap / 2
  const eyeRight = MATH_EYE.midX + MATH_EYE.gap / 2

  const eye = (side: 'l' | 'r', cx: number) => {
    const placement = mathEyeRest(cx)

    return (
      <g
        data-hb-eye={side}
        data-hb-rest={placement}
        data-hb-size={`${MATH_EYE.width} ${MATH_EYE.height}`}
        transform={placement}
      >
        <path d={curveEye(surface, MATH_EYE_SIZE, parseTransform(placement))} fill={eyeFillFor(color)} />
      </g>
    )
  }

  return (
    <svg
      aria-hidden
      className="block overflow-visible"
      data-bot-face={name}
      data-hb-key={`${shape}${color}`}
      data-hb-math="1"
      data-hb-mood={mood}
      data-hb-shape={shape || 'circle'}
      data-hb-tone={faceTone(color)}
      height={size}
      style={blinkStyle(name)}
      viewBox="0 0 40 44"
      width={size}
    >
      <g transform={MATH_FIGURE_TRANSFORM}>
        <path d={bodyPath} data-hb-body="1" fill={color} stroke={color} strokeLinejoin="round" strokeWidth={13} />
        <g data-hb-bounds={mathBounds(shape, ring)} data-hb-gaze="" {...surfaceAttributes(surface)}>
          <g data-hb-lids="">
            {eye('l', eyeLeft)}
            {eye('r', eyeRight)}
          </g>
        </g>
      </g>
      <g>
        <circle cx={16.4} cy={41.2} data-hb-dot="1" fill={color} opacity={restDots[0]} r={1.15} />
        <circle cx={20} cy={41.2} data-hb-dot="1" fill={color} opacity={restDots[1]} r={1.15} />
        <circle cx={23.6} cy={41.2} data-hb-dot="1" fill={color} opacity={restDots[2]} r={1.15} />
      </g>
    </svg>
  )
}

/** The friendly violet the primary profile has always worn, and the last
 *  resort for a draft that has no name to derive a hue from yet. */
const PRIMARY_AVATAR_COLOR = '#8b5cf6'

/** A picked color wins; with none, fall back to the name's deterministic hue —
 *  the same one `botAppearance` seeds — so "no choice" means the app's color
 *  rather than an arbitrary constant. */
export function avatarColor(color: null | string | undefined, name: string): string {
  return safeAvatarColor(color) || profileColor(name) || PRIMARY_AVATAR_COLOR
}

export function botAppearance(name: string, meta: BotMeta | null | undefined): AvatarAppearance {
  // The primary profile is literally named "default"; the SDK's profileColor
  // can hand it a near-black that renders as an ugly black square, and any
  // auto-seeded color in local bot-meta would otherwise stick. Give the
  // primary a nice fixed generic look (a friendly violet squircle). A user's
  // EXPLICIT customization still wins: an uploaded/generated/pet image, or a
  // shape/color they set via the editor (tracked by meta.custom === true).
  const isPrimary = (name || '').trim().toLowerCase() === 'default'
  const userCustomized = Boolean(meta?.custom)

  if (isPrimary && !userCustomized) {
    return {
      shape: 'squircle',
      color: PRIMARY_AVATAR_COLOR,
      image: meta?.image || null
    }
  }

  return {
    shape: meta?.shape || defaultShapeFor(name),
    color: safeAvatarColor(meta?.color) || profileColor(name),
    image: meta?.image || null
  }
}
