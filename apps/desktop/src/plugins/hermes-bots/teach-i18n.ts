import { usePluginI18n } from '@hermes/plugin-sdk'
import { useMemo } from 'react'

import { bind, type Bound } from './i18n-bind'
import { TEACH_LOCALES, type TeachMessages } from './teach-locales'

export type TeachText = Bound<TeachMessages>

/** The teach-a-skill strings for the active locale; registered through `TEACH_BUNDLES` next to the plugin's own. */
export function useTeach(): TeachText {
  const t = usePluginI18n('hermes-bots')

  return useMemo(() => bind(t, TEACH_LOCALES.en, 'teach'), [t])
}
