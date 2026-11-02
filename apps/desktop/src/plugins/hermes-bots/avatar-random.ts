import { AVATAR_PICKER_SHAPES, BLOB_KINDS, blobatarSvg, blobShapeString } from './avatar'
import { AVATAR_SWATCHES } from './avatar-swatches'

export interface RandomAvatarLook {
  color: string
  shape: string
}

const pick = <T>(items: readonly T[], random: () => number): T =>
  items[Math.min(items.length - 1, Math.floor(random() * items.length))]

export function randomAvatarLook(random: () => number = Math.random): RandomAvatarLook {
  const color = pick(AVATAR_SWATCHES, random)

  if (!blobatarSvg) {
    return { color, shape: pick(AVATAR_PICKER_SHAPES, random) }
  }

  const seed = Math.floor(random() * 36 ** 8)
    .toString(36)
    .padStart(8, '0')

  return { color, shape: blobShapeString(seed, pick(BLOB_KINDS, random)) }
}
