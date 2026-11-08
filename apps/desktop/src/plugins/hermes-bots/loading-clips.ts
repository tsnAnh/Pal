import * as sdk from '@hermes/plugin-sdk'

import { type LoadingClip, parseLoadingClips } from './avatar-motion'

let clips: readonly LoadingClip[] | undefined

export function loadingClips(): readonly LoadingClip[] {
  clips ??= 'avatarLoadingClips' in sdk ? parseLoadingClips(sdk.avatarLoadingClips) : []

  return clips
}
