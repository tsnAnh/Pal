export const EXTENDED_BLOB_KINDS = ['spark', 'clover', 'burst', 'gem'] as const

export type ExtendedBlobKind = (typeof EXTENDED_BLOB_KINDS)[number]

const BLOB_WITH_EYES = /^(<svg[^>]*>)<g fill="([^"]+)">(.*?)<\/g>(<g fill="[^"]+">.*)$/s
const BODY_PATH = /\sd="([^"]+)"/
const NUMBER = /-?\d+(?:\.\d+)?/g

const STARS: Record<'burst' | 'spark', { points: number; tip: number; valley: number }> = {
  spark: { points: 4, tip: 1.15, valley: 0.54 },
  burst: { points: 7, tip: 1.1, valley: 0.6 }
}

const GEM = { sides: 5, radius: 1.06, round: 0.24 }
const CLOVER = { reach: 0.55, petal: 0.52, lobes: 4 }

const r2 = (value: number) => String(Math.round(value * 100) / 100)
const toFixed2 = (value: number) => Number(value.toFixed(2))

export const isExtendedBlobKind = (kind: string): kind is ExtendedBlobKind =>
  (EXTENDED_BLOB_KINDS as readonly string[]).includes(kind)

function starPath(star: (typeof STARS)['burst'], cx: number, cy: number, r: number) {
  const vertices = Array.from({ length: star.points * 2 }, (_, index) => {
    const radius = (index % 2 === 0 ? star.tip : star.valley) * r
    const angle = -Math.PI / 2 + (Math.PI * index) / star.points

    return `${r2(cx + Math.cos(angle) * radius)} ${r2(cy + Math.sin(angle) * radius)}`
  })

  return `M${vertices.join('L')}Z`
}

function gemPath(cx: number, cy: number, r: number) {
  const radius = r * GEM.radius
  const k = GEM.round < 1 ? GEM.round / 2 : 0.5
  const start = -Math.PI / 2

  const vertices = Array.from({ length: GEM.sides }, (_, index) => {
    const angle = start + (2 * Math.PI * index) / GEM.sides

    return [cx + radius * Math.cos(angle), cy + radius * Math.sin(angle)] as const
  })

  const at = (index: number) => vertices[((index % GEM.sides) + GEM.sides) % GEM.sides]

  const cut = (from: number, to: number) => {
    const [x0, y0] = at(from)
    const [x1, y1] = at(to)

    return `${r2(x0 + (x1 - x0) * k)} ${r2(y0 + (y1 - y0) * k)}`
  }

  let d = `M${cut(0, -1)}`

  for (let index = 0; index < GEM.sides; index += 1) {
    const [x, y] = at(index)

    d += `Q${r2(x)} ${r2(y)} ${cut(index, index + 1)}`

    if (k < 0.5) {
      d += `L${cut(index + 1, index)}`
    }
  }

  return `${d}Z`
}

function cloverBody(cx: number, cy: number, r: number) {
  const lobes = Array.from({ length: CLOVER.lobes }, (_, index) => {
    const angle = Math.PI / 4 + (Math.PI / 2) * index

    return [cx + Math.cos(angle) * r * CLOVER.reach, cy + Math.sin(angle) * r * CLOVER.reach] as const
  })

  return [...lobes, [cx, cy] as const]
    .map(([x, y]) => `<circle cx="${r2(x)}" cy="${r2(y)}" r="${r2(r * CLOVER.petal)}"/>`)
    .join('')
}

function bodyMarkup(kind: ExtendedBlobKind, cx: number, cy: number, r: number) {
  switch (kind) {
    case 'spark':

    case 'burst':
      return `<path d="${starPath(STARS[kind], cx, cy, r)}"/>`

    case 'gem':
      return `<path d="${gemPath(cx, cy, r)}"/>`

    case 'clover':
      return `${cloverBody(cx, cy, r)}<path d="M${r2(cx)} ${r2(cy)}Z"/>`
  }
}

export function extendBlob(svg: string, kind: ExtendedBlobKind): string {
  const parts = BLOB_WITH_EYES.exec(svg)
  const d = parts && BODY_PATH.exec(parts[3])?.[1]

  if (!parts || !d) {
    return svg
  }

  const values = (d.match(NUMBER) ?? []).map(Number)
  const xs = values.filter((_, i) => i % 2 === 0)
  const ys = values.filter((_, i) => i % 2 === 1)

  if (xs.length < 3 || ys.length < 3 || values.some(value => !Number.isFinite(value))) {
    return svg
  }

  const cx = toFixed2((Math.min(...xs) + Math.max(...xs)) / 2)
  const cy = toFixed2((Math.min(...ys) + Math.max(...ys)) / 2)
  const r = toFixed2((Math.max(...xs) - Math.min(...xs) + Math.max(...ys) - Math.min(...ys)) / 4)

  return `${parts[1]}<g fill="${parts[2]}">${bodyMarkup(kind, cx, cy, r)}</g>${parts[4]}`
}
