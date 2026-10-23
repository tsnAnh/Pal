import type { TabStripMode } from '@/components/pane-shell/tree/model'
import { type Codec, persistentAtom } from '@/lib/persisted'
import { readKey } from '@/lib/storage'

const LEGACY_TAB_STRIP_DEFAULT_STORAGE_KEY = 'hermes.desktop.tabStripDefault'
const TAB_STRIP_DEFAULT_STORAGE_KEY = 'hermes.desktop.tabStripDefault.v2'

/** What a zone does when it has made no choice of its own. */
export type TabStripDefault = 'auto' | TabStripMode

const isTabStripDefault = (raw: null | string): raw is TabStripDefault =>
  raw === 'always' || raw === 'auto' || raw === 'never'

const codec: Codec<TabStripDefault> = {
  decode: raw => (isTabStripDefault(raw) ? raw : 'never'),
  encode: value => value
}

/**
 * The legacy key stored `auto` as an absent key, so absent cannot be told from
 * untouched: it gets the new hidden default. Explicit `always` / `never` carry
 * over. The legacy key is left in place so a rollback still finds it.
 */
function legacyTabStripDefault(): TabStripDefault {
  const raw = readKey(LEGACY_TAB_STRIP_DEFAULT_STORAGE_KEY)

  return isTabStripDefault(raw) ? raw : 'never'
}

/**
 * The app-wide answer for zones with no choice of their own, VS Code's
 * `workbench.editor.showTabs` and Zed's `tab_bar.show`. `never` is the product
 * default; `auto` keeps the contextual rule (a lone pane is not a tab);
 * `always` shows strips everywhere.
 *
 * A zone that states its own preference still wins. A lone closeable tile or
 * tool panel keeps its strip unless the zone itself says never (see
 * resolveTabStripVisible).
 */
export const $tabStripDefault = persistentAtom<TabStripDefault>(
  TAB_STRIP_DEFAULT_STORAGE_KEY,
  legacyTabStripDefault(),
  codec
)

export function setTabStripDefault(value: TabStripDefault) {
  $tabStripDefault.set(value)
}
