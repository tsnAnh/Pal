import { renderToStaticMarkup } from 'react-dom/server'

import { blobatar } from 'blobatar/blob'

import {
  avatarColor,
  BotFace,
  botAppearance,
  defaultShapeFor,
  isBlobShape,
  parseBlobShape
} from '../../../desktop/src/plugins/hermes-bots/avatar'
import { eyeFillFor, isDarkAvatarColor, safeAvatarColor } from '../../../desktop/src/plugins/hermes-bots/avatar-color'
import { profileColor } from '../../../desktop/src/lib/profile-color'
import { normalizeHex, readableInk } from '../../../desktop/src/themes/color'
import { traits as blobatarTraits } from 'blobatar'
import { layout as blobatarLayout } from 'blobatar/blob'

const SVG_NS = 'xmlns="http://www.w3.org/2000/svg"'

const BLOB_HSL = /^hsla?\(\s*(-?[\d.]+)(?:deg)?[\s,]+([\d.]+)%[\s,]+([\d.]+)%/i

function hslToHex(color: string): null | string {
  const match = BLOB_HSL.exec(color.trim())

  if (!match) {
    return null
  }

  const hue = (((Number(match[1]) % 360) + 360) % 360) / 30
  const sat = Math.min(Number(match[2]), 100) / 100
  const light = Math.min(Number(match[3]), 100) / 100
  const spread = sat * Math.min(light, 1 - light)

  const channel = (offset: number) => {
    const k = (offset + hue) % 12
    const value = light - spread * Math.max(-1, Math.min(k - 3, 9 - k, 1))

    return Math.round(value * 255)
      .toString(16)
      .padStart(2, '0')
  }

  return `#${channel(0)}${channel(8)}${channel(4)}`
}

export function renderCase(testCase: any, size: number) {
  const appearance = botAppearance(testCase.name, testCase.meta)
  const color = avatarColor(appearance.color, testCase.name)
  const hasPhoto = Boolean(appearance.image)

  const markup = renderToStaticMarkup(
    <BotFace
      color={appearance.color as string}
      image={appearance.image}
      mood={testCase.mood}
      name={testCase.name}
      shape={appearance.shape}
      size={size}
    />
  )

  const svgStart = markup.indexOf('<svg')
  let svg: null | string = null

  if (svgStart >= 0) {
    svg = markup.slice(svgStart, markup.lastIndexOf('</svg>') + 6)

    if (!svg.includes(SVG_NS)) {
      svg = svg.replace('<svg ', `<svg ${SVG_NS} `)
    }
  }

  const resolved: Record<string, unknown> = {
    shape: appearance.shape,
    appearanceColor: appearance.color,
    color,
    hasImage: hasPhoto
  }

  if (hasPhoto) {
    resolved.kind = 'photo'
  } else if (isBlobShape(appearance.shape)) {
    const parsed = parseBlobShape(appearance.shape, testCase.name)

    resolved.kind = 'blob'
    resolved.seed = parsed.seed
    resolved.pinnedKind = parsed.kind
    resolved.customBody = Boolean(safeAvatarColor(color) && safeAvatarColor(color) !== profileColor(testCase.name))

    const fills = svg ? [...svg.matchAll(/ fill="([^"]+)"/g)].map(m => m[1]) : []

    resolved.headFill = fills[0] ?? null
    resolved.eyeFill = fills[1] ?? null
  } else if (appearance.shape.startsWith('sigil-')) {
    resolved.kind = 'sigil'
  } else {
    resolved.kind = 'classic'
    resolved.eyeFill = eyeFillFor(color)
  }

  return { svg, resolved }
}

export function colorGolden(input: string) {
  const safe = safeAvatarColor(input)

  return {
    input,
    safe,
    dark: safe ? isDarkAvatarColor(safe) : null,
    eye: safe ? eyeFillFor(safe) : null,
    hex: normalizeHex(input)
  }
}

export function nameGolden(name: string) {
  return { name, profileColor: profileColor(name), defaultShape: defaultShapeFor(name) }
}

export function shapeGolden(shape: string, name: string) {
  const parsed = parseBlobShape(shape, name)

  return { shape, name, isBlob: isBlobShape(shape), seed: parsed.seed, seedPart: parsed.seedPart, kind: parsed.kind }
}

export function figureGolden(seed: string, shapeTrait?: number) {
  const options = shapeTrait === undefined ? {} : { traits: { shape: shapeTrait } }
  const traits = blobatarTraits(seed, true, shapeTrait === undefined ? undefined : { shape: shapeTrait })

  return { seed, shapeTrait: shapeTrait ?? null, silhouette: blobatarLayout(traits).shape, svg: blobatar(seed, options) }
}

export function accentGolden(name: string, meta: Record<string, unknown>) {
  const appearance = botAppearance(name, meta as any)
  const resolved = avatarColor(appearance.color, name)
  const accent = normalizeHex(resolved) ?? hslToHex(resolved)

  return { name, meta, resolved, accent, foreground: accent ? readableInk(accent) : null }
}
