/**
 * Does this zone show its tab strip? One resolver, one precedence order, so
 * every caller gets the same answer and the rule can be read in one place.
 *
 * The decision used to be an inline expression in TreeGroup fed by a flag four
 * other code paths also wrote to, which is how a zone could end up with no
 * strip, no tab, no ✕ and no menu to get any of them back. The ladder below is
 * the whole policy; nothing outside `mode` is persisted, so a zone's chrome is
 * a function of what it currently holds plus one deliberate choice.
 */

import type { Contribution } from '@/contrib/types'
import { $tabStripDefault, type TabStripDefault } from '@/store/tabstrip-prefs'

import type { TabStripMode } from '../model'

import { paneChrome } from './track-model'

export interface StripPane {
  /** A tool panel (terminal / logs) that collapses rather than closes. */
  collapsePane: boolean
  /** Contribution placement — `'main'` marks a docked tile (session, page,
   *  preview) as opposed to standing side chrome. */
  placement?: string
  /** Panes that never leave the tree (the workspace). */
  uncloseable?: boolean
}

export interface StripZone {
  /** The ACTIVE pane declines to be tabbed (a full-page view). */
  headerVeto?: boolean
  /** The zone's own choice; undefined = defer to the app default. */
  mode?: TabStripMode
  /** The app-wide default, applied when the zone has no choice. */
  fallback?: TabStripDefault
  /** Panes currently rendered as chips — chrome-hidden and narrow-collapsed
   *  panes are already filtered out. */
  shown: readonly StripPane[]
}

/**
 * A pane is STRANDED without a strip when the strip is the only thing carrying
 * its handle: a lone closeable tile needs its ✕, a lone tool panel needs a
 * chip to grab. The workspace is exempt: it cannot leave the tree, and the
 * chat zone is deliberately chromeless under the app default. Hide-only chrome
 * (sessions / Bots) is different: the panes stay, Show/Hide is a separate verb,
 * and a hidden strip comes back via ⌘⌥T.
 *
 * Only a LONE pane is protected. A stack of two or more answers tab cycling and
 * ⌘1…⌘9, so hiding its strip costs chrome and no handle.
 */
function stranded(shown: readonly StripPane[]): boolean {
  if (shown.length !== 1) {
    return false
  }

  const [only] = shown

  if (only.uncloseable) {
    return false
  }

  return only.collapsePane || only.placement === 'main'
}

export function resolveTabStripVisible(zone: StripZone): boolean {
  if (zone.shown.length === 0) {
    return false
  }

  if (zone.headerVeto) {
    return false
  }

  if (zone.mode) {
    return zone.mode === 'always'
  }

  if (stranded(zone.shown)) {
    return true
  }

  const fallback = zone.fallback ?? 'auto'

  if (fallback !== 'auto') {
    return fallback === 'always'
  }

  return zone.shown.length > 1 || zone.shown[0].uncloseable === true
}

/**
 * Resolve a zone straight from what the layout knows about it. Both callers —
 * TreeGroup from its render inputs, the store from the registry — go through
 * here, so neither can drift on which chrome flags feed the answer or forget to
 * fold in the app-wide default.
 */
export function tabStripVisibleForZone(zone: {
  /** The zone's ACTIVE pane. */
  active: string
  isCollapsePane: (id: string) => boolean
  /** The zone's own choice, before the app default applies. */
  mode: TabStripMode | undefined
  paneFor: (id: string) => Contribution | undefined
  /** Panes currently rendered as chips. */
  shown: readonly string[]
}): boolean {
  return resolveTabStripVisible({
    headerVeto: paneChrome(zone.paneFor(zone.active)).headerVeto,
    fallback: $tabStripDefault.get(),
    mode: zone.mode,
    shown: zone.shown.map(id => {
      const chrome = paneChrome(zone.paneFor(id))

      return {
        collapsePane: zone.isCollapsePane(id),
        placement: chrome.placement,
        uncloseable: chrome.uncloseable
      }
    })
  })
}
