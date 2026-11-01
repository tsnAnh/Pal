// Contribution-area constants the SDK barrel re-exports whole: host-owned
// areas with no feature module of their own, plus area contracts whose module
// lives in core but has no other public door.

export const PANES_AREA = 'panes'
export const STATUSBAR_AREAS = { left: 'statusBar.left', right: 'statusBar.right' } as const
/** Titlebar slots are PERMANENT mount points: a component registered here
 *  stays mounted across chat ↔ page navigation, so `useEffect` setup/cleanup
 *  runs once per registration, not once per route. Page-owned controls that
 *  should exist only while a page is up go to `WORKSPACE_PAGE_HEADER_AREA`. */
export const TITLEBAR_AREAS = { center: 'titleBar.center', left: 'titleBar.left', right: 'titleBar.right' } as const
/** The Connect apps data for a plugin-owned catalog: every app the Connectors
 *  tab offers (curated apps first), its status, the existing connect and
 *  reconnect flows, and per-bot access (`bots`) written the way that bot's
 *  Connectors tab writes it. Headless; render it with your own copy. Probe
 *  `typeof useConnectorApps === 'function'` first: older builds lack it. */
export { type AppBot, type BotAccess, type BotAppFailure } from '@/app/capabilities/connectors/apps/bot-access'
export {
  type AppAction,
  type AppAvailability,
  type AppEntry,
  type AppsCatalog,
  type AppStatus,
  filterApps
} from '@/app/capabilities/connectors/apps/catalog'
export { type ConnectorAppsView, useConnectorApps } from '@/app/capabilities/connectors/apps/use-connector-apps'
/** The vendor mark every connector row draws. */
export { ConnectorLogo } from '@/components/ui/connector-logo'
/** Per-card labels on Kanban tiles: register a `KANBAN_CARD_AREAS.badges`
 *  data contribution whose `decorate({ id, status, tenant, assignee },
 *  { tenants })` returns `{ label, tone?, tooltip? }` (or a few, or `null`). Core paints
 *  them as text chips in the card's badge row, ordered by plugin id, capped
 *  per plugin, removed with the plugin. Never touch the board's markup.
 *  `KanbanCardBadges` is the row the board itself renders. */
export {
  KANBAN_CARD_AREAS,
  KANBAN_CARD_BADGE_HUES,
  KANBAN_CARD_BADGE_LIMITS,
  type KanbanCard,
  type KanbanCardBadge,
  type KanbanCardBadgeContribution,
  type KanbanCardBadgeHue,
  KanbanCardBadges,
  type KanbanCardBadgeTone,
  type KanbanCardBoard
} from '@/contrib/kanban-card-badges'
/** Draw the transcript card of a host tool with plugin-owned UI (Bot Mode's hand-back card). */
export {
  TOOL_CARD_AREA,
  type ToolCardContribution,
  type ToolCardProps
} from '@/lib/tool-card-renderers'
/** Draw the `MEDIA:` files your package's OWN tools produced, in place of the
 *  built-in player (ownership is checked against the backend's tool registry). */
export {
  TOOL_MEDIA_RENDERER_AREA,
  type ToolMediaFile,
  type ToolMediaRendererContribution,
  type ToolMediaRendererProps
} from '@/lib/tool-media-renderers'
