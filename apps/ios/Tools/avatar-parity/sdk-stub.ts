import { traits as blobatarTraits, type TraitOverrides } from 'blobatar'
import { blobatar, layout as blobatarLayout } from 'blobatar/blob'

export { profileColor } from '../../../desktop/src/lib/profile-color'
export { normalizeHex, readableInk as readableOn } from '../../../desktop/src/themes/color'

export const blobatarSvg = blobatar

export const blobatarSilhouette = (seed: string, overrides?: TraitOverrides): string =>
  blobatarLayout(blobatarTraits(seed, true, overrides)).shape

export const createBudgetedLoop = undefined
