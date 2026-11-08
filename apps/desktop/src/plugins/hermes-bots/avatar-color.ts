const NUMBER = '[+-]?(?:\\d+\\.?\\d*|\\.\\d+)'
const COMPONENT = `${NUMBER}%?`
const HUE = `${NUMBER}(?:deg)?`
const SEPARATOR = '(?:\\s*,\\s*|\\s+)'
const ALPHA_SEPARATOR = '(?:\\s*,\\s*|\\s*/\\s*)'

const HEX = /^#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i

const RGB = new RegExp(
  `^rgba?\\(\\s*(${COMPONENT})${SEPARATOR}(${COMPONENT})${SEPARATOR}(${COMPONENT})(?:${ALPHA_SEPARATOR}${COMPONENT})?\\s*\\)$`,
  'i'
)

const HSL = new RegExp(
  `^hsla?\\(\\s*(${HUE})${SEPARATOR}(${COMPONENT})${SEPARATOR}(${COMPONENT})(?:${ALPHA_SEPARATOR}${COMPONENT})?\\s*\\)$`,
  'i'
)

const DARK_LUMINANCE = 110
const WHITE_LUMINANCE = 230

type Rgb = [number, number, number]

export function safeAvatarColor(value: unknown): null | string {
  if (typeof value !== 'string') {
    return null
  }

  return HEX.test(value) || RGB.test(value) || HSL.test(value) ? value : null
}

function channel(text: string): number {
  const value = Number.parseFloat(text)

  return Math.min(255, Math.max(0, text.endsWith('%') ? (value / 100) * 255 : value))
}

function hexRgb(hex: string): Rgb {
  const digits = hex.slice(1)
  const full = digits.length <= 4 ? [...digits].map(d => d + d).join('') : digits
  const n = Number.parseInt(full.slice(0, 6), 16)

  return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
}

function hslRgb(hueText: string, satText: string, lightText: string): Rgb {
  const h = (((Number.parseFloat(hueText) % 360) + 360) % 360) / 360
  const s = Math.min(1, Math.max(0, Number.parseFloat(satText) / 100))
  const l = Math.min(1, Math.max(0, Number.parseFloat(lightText) / 100))
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s
  const p = 2 * l - q

  const at = (offset: number) => {
    const t = (h + offset + 1) % 1

    if (t < 1 / 6) {
      return p + (q - p) * 6 * t
    }

    if (t < 1 / 2) {
      return q
    }

    if (t < 2 / 3) {
      return p + (q - p) * (2 / 3 - t) * 6
    }

    return p
  }

  return [at(1 / 3) * 255, at(0) * 255, at(-1 / 3) * 255]
}

function colorRgb(value: string): null | Rgb {
  if (HEX.test(value)) {
    return hexRgb(value)
  }

  const rgb = RGB.exec(value)

  if (rgb) {
    return [channel(rgb[1]), channel(rgb[2]), channel(rgb[3])]
  }

  const hsl = HSL.exec(value)

  return hsl ? hslRgb(hsl[1], hsl[2], hsl[3]) : null
}

function luminance(value: string): null | number {
  const rgb = colorRgb(value)

  return rgb ? 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2] : null
}

export function isDarkAvatarColor(value: string): boolean {
  const level = luminance(value)

  return level !== null && level < DARK_LUMINANCE
}

export function isWhiteAvatarColor(value: string): boolean {
  const level = luminance(value)

  return level !== null && level >= WHITE_LUMINANCE
}

export const LIGHT_EYE_FILL = '#f3f4fd'
export const DARK_EYE_FILL = '#1b1b1b'

export function eyeFillFor(bodyColor: string): string {
  return isDarkAvatarColor(bodyColor) ? LIGHT_EYE_FILL : DARK_EYE_FILL
}

export function attributeText(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}
