/**
 * The two rows the Bots rail lists: one bot, and one group chat.
 *
 * Rows only. Both take their bot or room and their context-menu callbacks as
 * props and own no roster state, so the pane above them decides what to list
 * and the row decides only how it reads.
 */

import {
  cn,
  Codicon,
  ContextMenu,
  ContextMenuCheckboxItem,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
  ContextMenuSub,
  ContextMenuSubContent,
  ContextMenuSubTrigger,
  ContextMenuTrigger,
  GlyphSpinner,
  haptic,
  host,
  queryClient,
  RowButton,
  Tip,
  useI18n,
  useValue
} from '@hermes/plugin-sdk'

import { avatarColor, botAppearance, BotFace } from './avatar'
import { isBackfilledFacePng } from './avatar-image'
import {
  $botChatFocused,
  $focusedBotOwner,
  $pendingBotOpen,
  $selectedRosterKey,
  focusedRosterOwner,
  saveSelectedRosterBot
} from './bot-state'
import { BotShareSubmenu } from './bot-template-export'
import { ensureBotMetadata, ensureBotProfile } from './canonical-chat'
import {
  $botAttention,
  $botMeta,
  $lastRoster,
  botActivitySession,
  botAttentionHint,
  botHandle,
  botRosterKey,
  botSelectionKey,
  botSourceStatus,
  isDefaultBot,
  newBotChat,
  ROSTER_KEY,
  saveBotMeta
} from './data'
import { $groupChats, $groupChatWorkspace } from './group-chat'
import { botGroups, groupLastActivity } from './group-membership'
import { toggleGroupChatPinned } from './group-pin'
import { $activeGroupMemberKeys } from './group-presence'
import { fallbackSelectionAfterHide, isBotHidden, isBotPinned } from './hidden-bots'
import { useBots } from './i18n'
import { displayName, stripPreviewMarkdown } from './labels'
import { duplicateBot } from './profile-ops'
import { botRecentSession, openBotRecentSession } from './recent-session'
import { openRosterBot } from './roster-actions'
import { rosterPreview } from './roster-preview'
import { botRosterMeta, botWorkspaceOwnerKey, setBotsWorkspaceOwner } from './routing'
import { rowAge } from './row-age'
import {
  botRowOwnsWorkspace,
  botWorkingMood,
  useTurnBusy,
  workerActiveAt
} from './row-helpers'
import { openBotScreen } from './screen-open'
import type { GroupMember, RosterRow } from './types'
import {
  $botSections,
  $draggingBot,
  BOT_DRAG_MIME,
  botSectionId,
  groupChatSectionId,
  groupDragKey,
  moveBotsToSection,
  moveGroupChatsToSection
} from './user-sections'

// ── bot row ──────────────────────────────────────────────────────────────────

interface BotRowProps {
  bot: RosterRow
  onDelete: (bot: RosterRow) => void
  onEdit: (bot: RosterRow) => void
  onGroup: (bot: RosterRow) => void
  /** Opens the New section dialog; the bot is filed into it on create. */
  onNewSection: (bot: RosterRow) => void
  showHandle?: boolean
  variant?: 'row' | 'tile'
}

const CLUSTER_FACES = 3
const CLUSTER_FACE_SIZE = 30

function GroupFaceCluster({ members, muted }: { members: GroupMember[]; muted: boolean }) {
  const allMeta = useValue($botMeta)
  const shown = members.slice(0, CLUSTER_FACES)

  return (
    <div
      className={cn('relative size-12', muted && 'grayscale opacity-60')}
      data-slot="group-face-cluster"
    >
      {shown.map((member, index) => {
        const { shape, color, image } = botAppearance(member.name, botRosterMeta(member, allMeta))
        const photo = Boolean(image && !isBackfilledFacePng(image))
        const offset = shown.length === 1 ? 9 : (index * (48 - CLUSTER_FACE_SIZE)) / (shown.length - 1)

        return (
          <span
            className="absolute rounded-full bg-(--ui-bg-chrome,var(--background)) p-px"
            key={`${member.connectionId ?? ''}::${member.name}`}
            style={{ left: offset, top: index % 2 === 0 ? 0 : 48 - CLUSTER_FACE_SIZE - 2, zIndex: shown.length - index }}
          >
            <BotFace
              color={avatarColor(color, member.name)}
              image={photo ? image : null}
              name={member.name}
              shape={shape}
              size={CLUSTER_FACE_SIZE - 2}
            />
          </span>
        )
      })}
    </div>
  )
}

function duplicateBotFromRow(bot: RosterRow, label: string, failedMessage: string) {
  host.notify({
    kind: 'info',
    message: `Duplicating ${label}…`
  })
  duplicateBot(bot, $lastRoster.get())
    .then(name => {
      queryClient.invalidateQueries({
        queryKey: ROSTER_KEY
      })
      host.notify({
        kind: 'success',
        message: `Created ${name} — full copy of ${bot.name}`
      })
    })
    .catch(err => host.notifyError(err, failedMessage))
}

export function BotRow({ bot, onDelete, onEdit, onGroup, onNewSection, showHandle, variant = 'row' }: BotRowProps) {
  const { t } = useI18n()
  const b = useBots()
  const focusedOwner = focusedRosterOwner(useValue($focusedBotOwner))
  const selectedRosterKey = useValue($selectedRosterKey)
  const pendingOpenKey = useValue($pendingBotOpen)?.key
  const isOpening = pendingOpenKey === botRosterKey(bot)
  const botChatFocused = useValue($botChatFocused)
  const activeGroup = useValue($groupChatWorkspace)
  const allMeta = useValue($botMeta)
  const meta = botRosterMeta(bot, allMeta)
  const hidden = isBotHidden(bot, allMeta)
  const pinned = isBotPinned(bot, allMeta)
  const sourceStatus = botSourceStatus(bot)
  const groups = botGroups(meta)
  const last = bot.last_session
  // Highlight follows the chat on screen (focused session's owner), not the
  // gateway socket's home — a focused tab doesn't swap the socket, and on the
  // old keying the wrong bot stayed highlighted while you read another's chat.
  // A selected group chat suppresses every bot-row highlight: the group row
  // owns the selection then (#88979).
  const activeConnectionId = String(host.state.connectionId?.get?.() || 'local').trim()
  // The highlight follows whoever owns the MAIN workspace. While a chat owns
  // it, that chat's profile wins (a stale roster click must not key the
  // highlight to a bot you are not reading). With no focused chat, the
  // source-qualified selection is the owner — and it is the only rule that
  // can highlight a remote row, which has no focusable local chat.
  const isActive = botRowOwnsWorkspace(bot, activeGroup, botChatFocused, focusedOwner, selectedRosterKey)

  const { shape, color, image } = botAppearance(bot.name, meta)
  // Keep user photos/pets. Drop the 160px SVG backfill so the math face can move.
  const photo = Boolean(image && !isBackfilledFacePng(image))
  const turnBusy = useTurnBusy()
  const activitySession = botActivitySession(bot)
  // A live kanban/tool worker gates only the pulse/mood (#90268). The age is
  // the last time the bot did ANYTHING — chat or delegated worker run — so a
  // delegate-only specialist that ran all day no longer snaps back to "11d"
  // the moment the 150 s liveness window lapses (#105874). An absent
  // worker_session (past the gateway's 20-row window) degrades to chat age.
  const workerActive = workerActiveAt(bot)

  const groupKeys = useValue($activeGroupMemberKeys)
  const botMood = botWorkingMood(bot, focusedOwner, turnBusy, activeConnectionId, Date.now(), groupKeys)
  // Needs-attention badge (#93091 item 3): background failures record under
  // the selection key (group turns) or the route key (relay deliveries) —
  // check both. Local/unannotated rows carry no connectionId, so their relay
  // failures live under `<activeConnectionId>::<name>` — resolve that shape
  // too or active-gateway bots never badge. Hidden bots keep their entry;
  // hiding is display-only.
  const attentionByKey = useValue($botAttention)

  const attention =
    attentionByKey[botSelectionKey(bot)] ||
    attentionByKey[botRosterKey(bot)] ||
    attentionByKey[`${bot?.connectionId || activeConnectionId}::${bot?.name || 'default'}`] ||
    null

  const { fromBot, text: displayPreview } = rosterPreview(bot, meta, $lastRoster.get())

  const handle = botHandle(bot.name, bot)
  const gatewayLabel = bot.connectionLabel || (bot.connectionId === 'local' ? b.bot.thisDevice : '')
  const showDetailsRow = Boolean(showHandle || displayPreview || fromBot)

  const rowTooltip = [displayName(bot, meta), `@${handle}`, gatewayLabel, sourceStatus.label]
    .filter(Boolean)
    .join(' · ')

  const warm = () => {
    // Multi-source row: pre-dial the agent's OWN source (feature-detected).
    if (bot.sourceScoped && typeof host.warmAgent === 'function') {
      try {
        host.warmAgent(bot.connectionId, bot.name)
      } catch {
        /* warm is best-effort */
      }

      return
    }

    if (typeof host.warmProfile !== 'function') {
      return
    }

    try {
      host.warmProfile(bot.name)
    } catch {
      /* warm is best-effort */
    }
  }

  // Rows and Active Now share the exact-owner open path; only that path may
  // activate a source and resolve the canonical Bot Chat. ⌘/⌃-click opens
  // the Bot Chat as a stacked tab beside the current one (same modifier the
  // Sessions rows honour) instead of replacing whatever main holds.
  const open = (event?: { ctrlKey?: boolean; metaKey?: boolean }) =>
    void openRosterBot(bot, { intent: event?.metaKey || event?.ctrlKey ? 'tab' : 'in-place' })

  // DRAG lives on the row button itself: it already takes pointer events, so
  // the click that opens the bot and the drag that files it are one element's
  // gestures. The drag carries the roster key under a private MIME type, so
  // only a section block can accept it.
  const rosterKey = botRosterKey(bot)
  const sections = useValue($botSections)
  const dragging = useValue($draggingBot) === rosterKey
  const currentSectionId = botSectionId(bot, allMeta)

  const tileSubtitle = meta?.title || ''

  const tile = (
    <RowButton
      aria-busy={isOpening || undefined}
      aria-label={attention ? `${rowTooltip} · ${b.roster.needsAttention}` : rowTooltip}
      className={cn(
        'group/tile flex w-24 min-w-0 flex-col items-center gap-1.5 overflow-hidden rounded-xl px-1 py-1 text-center transition-opacity',
        'hover:opacity-80',
        dragging && 'opacity-40'
      )}
      data-bot-gaze-scope
      data-roster-key={rosterKey}
      draggable
      onClick={open}
      onDragEnd={() => $draggingBot.set(null)}
      onDragStart={event => {
        event.dataTransfer.setData(BOT_DRAG_MIME, rosterKey)
        event.dataTransfer.effectAllowed = 'move'
        $draggingBot.set(rosterKey)
      }}
      onPointerEnter={warm}
    >
      <div className={cn('relative shrink-0 rounded-full p-0.5', !sourceStatus.available && 'grayscale opacity-60')}>
        <BotFace
          color={avatarColor(color, bot.name)}
          image={photo ? image : null}
          mood={botMood}
          name={bot.name}
          shape={shape}
          size={72}
        />
        {isDefaultBot(bot) ? (
          <span
            aria-label={b.roster.mainBot}
            className="absolute bottom-0 right-0 grid size-[18px] place-items-center rounded-full bg-orange-500 text-white ring-2 ring-(--ui-bg-chrome,var(--background))"
            data-slot="bot-main-badge"
            role="img"
          >
            <Codicon className="text-[0.625rem] leading-none" name="star-full" />
          </span>
        ) : null}
        {attention ? (
          <Codicon
            aria-label={b.roster.needsAttention}
            className="absolute -bottom-1 -right-1 text-[0.6875rem] text-amber-600 dark:text-amber-300"
            name="warning"
          />
        ) : null}
        {isOpening ? (
          <GlyphSpinner
            ariaLabel={b.bot.openingChat}
            className="absolute -bottom-1 -left-1 text-xs text-(--ui-text-secondary)"
          />
        ) : null}
      </div>
      <span className="w-full truncate text-[0.875rem] leading-[18px] text-(--ui-text-secondary)">
        {displayName(bot, meta)}
      </span>
      {tileSubtitle ? (
        <span className="-mt-1 w-full truncate text-[0.75rem] leading-4 text-(--ui-text-tertiary)">{tileSubtitle}</span>
      ) : null}
    </RowButton>
  )

  const row =
    variant === 'tile' ? (
      tile
    ) : (
      <RowButton
        aria-busy={isOpening || undefined}
        aria-label={rowTooltip}
        className={cn(
          'flex min-h-14 w-full min-w-0 max-w-full items-center gap-3 overflow-hidden rounded-[14px] px-3 py-1.5 text-left transition-colors',
          'hover:bg-[color-mix(in_srgb,var(--bot-row-active,var(--chrome-action-hover))_55%,transparent)]',
          isActive && 'bg-(--ui-row-active-background) hover:bg-(--ui-row-active-background)',
          // The row being dragged fades in place; the browser's drag image is
          // the row itself, so the ghost under the pointer is the full row.
          dragging && 'opacity-40'
        )}
        data-bot-gaze-scope
        data-roster-key={rosterKey}
        draggable
        onClick={open}
        onDragEnd={() => $draggingBot.set(null)}
        onDragStart={event => {
          event.dataTransfer.setData(BOT_DRAG_MIME, rosterKey)
          event.dataTransfer.effectAllowed = 'move'
          $draggingBot.set(rosterKey)
        }}
        onPointerEnter={warm}
      >
        <div className={cn('relative shrink-0', !sourceStatus.available && 'grayscale opacity-60')}>
          <BotFace
            color={avatarColor(color, bot.name)}
            image={photo ? image : null}
            mood={botMood}
            name={bot.name}
            shape={shape}
            size={48}
          />
        </div>
        <div className="min-w-0 flex-1">
          <div className="flex items-baseline justify-between gap-2">
            <div className="flex min-w-0 items-center gap-1.5">
              {pinned ? (
                <Tip label={b.roster.pinned}>
                  <Codicon className="shrink-0 text-[0.6875rem] text-(--ui-text-quaternary)" name="pinned" />
                </Tip>
              ) : null}
              {hidden ? (
                <Tip label={b.roster.hiddenFromRoster}>
                  <Codicon className="shrink-0 text-[0.6875rem] text-(--ui-text-quaternary)" name="eye-closed" />
                </Tip>
              ) : null}
              <Tip label={rowTooltip}>
                <span className="min-w-0 truncate text-[0.9375rem] font-medium leading-5 text-foreground">
                  {displayName(bot, meta)}
                </span>
              </Tip>
            </div>
            {attention ? (
              <Tip label={botAttentionHint(attention.reason)}>
                <Codicon
                  aria-label={b.roster.needsAttention}
                  className="shrink-0 text-[0.6875rem] text-amber-600 dark:text-amber-300"
                  name="warning"
                />
              </Tip>
            ) : null}
            {isOpening ? (
              <GlyphSpinner ariaLabel={b.bot.openingChat} className="shrink-0 text-xs text-(--ui-text-secondary)" />
            ) : null}
          </div>
          {showDetailsRow ? (
            <div className="flex min-w-0 items-center gap-1.5 text-[0.8125rem] leading-[18px] text-(--ui-text-tertiary)">
              {showHandle ? (
                <span className="shrink-0 font-mono text-[0.6875rem] text-(--ui-text-quaternary)">{`@${handle}`}</span>
              ) : null}
              {showHandle && displayPreview ? <span className="shrink-0 text-(--ui-text-quaternary)">·</span> : null}
              {displayPreview ? (
                <span className={cn('min-w-0 truncate', fromBot && 'italic')}>{displayPreview}</span>
              ) : null}
            </div>
          ) : null}
        </div>
      </RowButton>
    )

  return (
    <ContextMenu>
      <ContextMenuTrigger asChild>{row}</ContextMenuTrigger>
      <ContextMenuContent>
        <ContextMenuItem onSelect={() => void openRosterBot(bot)}>{b.bot.openBotChat}</ContextMenuItem>
        <ContextMenuItem onSelect={() => void openRosterBot(bot, { intent: 'tab' })}>{b.bot.openBotChatInNewTab}</ContextMenuItem>
        <ContextMenuItem onSelect={() => openBotScreen(bot, meta)}>{b.screen.menu}</ContextMenuItem>
        <ContextMenuCheckboxItem
          checked={Boolean(meta?.screenAutoOpen)}
          onSelect={() => {
            void ensureBotMetadata(bot)
              .then(current => {
                const next = !current.screenAutoOpen
                void saveBotMeta(bot, { screenAutoOpen: next })
                host.notify({
                  kind: 'info',
                  message: next
                    ? b.screen.autoOpenOnToast(displayName(bot, current))
                    : b.screen.autoOpenOffToast(displayName(bot, current))
                })
              })
              .catch(error => host.notifyError?.(error, b.bot.metadataLoadFailed))
          }}
        >
          {b.screen.autoOpenMenu}
        </ContextMenuCheckboxItem>
        <ContextMenuSeparator />
        <ContextMenuItem
          onSelect={() => {
            void ensureBotMetadata(bot)
              .then(current => {
                const pinned = Boolean(current.pinned)
                void saveBotMeta(bot, {
                  pinned: !pinned
                })
                host.notify({
                  kind: 'info',
                  message: pinned
                    ? b.bot.unpinnedToast(displayName(bot, current))
                    : b.bot.pinnedToast(displayName(bot, current))
                })
              })
              .catch(error => host.notifyError?.(error, b.bot.metadataLoadFailed))
          }}
        >
          {pinned ? b.bot.unpin : b.bot.pinToTop}
        </ContextMenuItem>
        <ContextMenuItem
          onSelect={() => {
            void ensureBotMetadata(bot)
              .then(current => {
                const hidden = Boolean(current.hidden)
                void saveBotMeta(bot, {
                  hidden: !hidden
                })

                if (!hidden) {
                  fallbackSelectionAfterHide(botSelectionKey(bot))
                }

                host.notify({
                  kind: 'info',
                  message: hidden
                    ? b.bot.unhiddenToast(displayName(bot, current))
                    : b.bot.hiddenToast(displayName(bot, current))
                })
              })
              .catch(error => host.notifyError?.(error, b.bot.metadataLoadFailed))
          }}
        >
          {hidden ? b.bot.unhide : b.bot.hide}
        </ContextMenuItem>
        <ContextMenuSeparator />
        <ContextMenuItem
          onSelect={() =>
            void ensureBotProfile(bot)
              .then(onEdit)
              .catch(error => host.notifyError?.(error, b.bot.loadFailed))
          }
        >
          {b.bot.editMenu}
        </ContextMenuItem>
        <ContextMenuItem
          onSelect={() =>
            void ensureBotMetadata(bot)
              .then(() => onGroup(bot))
              .catch(error => host.notifyError?.(error, b.bot.groupsLoadFailed))
          }
        >
          {groups.length ? b.bot.groupsMenu(groups.join(', ')) : b.bot.manageGroups}
        </ContextMenuItem>
        <ContextMenuItem onSelect={() => duplicateBotFromRow(bot, displayName(bot, meta), b.bot.duplicateFailed)}>
          {b.bot.duplicate}
        </ContextMenuItem>
        <BotShareSubmenu bot={bot} />
        <ContextMenuSeparator />
        <ContextMenuItem
          onSelect={() => {
            saveSelectedRosterBot(bot)
            setBotsWorkspaceOwner(botWorkspaceOwnerKey(bot), bot)
            newBotChat(bot)
          }}
        >
          {b.bot.newChatWith}
        </ContextMenuItem>
        {/* Click-to-latest (#93054): the freshest listed session — a cron run,
            a delegated job, a side thread — without moving the row click off
            the canonical Bot Chat. */}
        <ContextMenuItem disabled={!botRecentSession(bot)} onSelect={() => void openBotRecentSession(bot)}>
          Open recent session
        </ContextMenuItem>
        <ContextMenuSeparator />
        {/* Filing. Membership is one field on the bot's meta (`sectionId`), so
            this is a one-field write and no list anywhere has to be kept in
            sync with it. */}
        <ContextMenuSub>
          <ContextMenuSubTrigger>{b.sections.moveTo}</ContextMenuSubTrigger>
          <ContextMenuSubContent>
            {sections.map(section => (
              <ContextMenuItem
                disabled={section.id === currentSectionId}
                key={section.id}
                onSelect={() => void moveBotsToSection([bot], section.id)}
              >
                <Codicon className="mr-1.5" name="folder" />
                {section.name}
              </ContextMenuItem>
            ))}
            {sections.length ? <ContextMenuSeparator /> : null}
            <ContextMenuItem onSelect={() => onNewSection(bot)}>
              <Codicon className="mr-1.5" name="new-folder" />
              {b.sections.newSectionEllipsis}
            </ContextMenuItem>
            {currentSectionId ? (
              <ContextMenuItem onSelect={() => void moveBotsToSection([bot], null)}>
                <Codicon className="mr-1.5" name="inbox" />
                {b.sections.removeFromSection}
              </ContextMenuItem>
            ) : null}
          </ContextMenuSubContent>
        </ContextMenuSub>
        {isDefaultBot(bot) ? null : <ContextMenuSeparator />}
        {isDefaultBot(bot) ? null : (
          <ContextMenuItem onSelect={() => onDelete(bot)} variant="destructive">
            {t.common.delete}
          </ContextMenuItem>
        )}
      </ContextMenuContent>
    </ContextMenu>
  )
}

/** One group chat as one quiet roster row. The room owns one visual identity;
 *  member details stay in its tooltip and workspace instead of competing
 *  with bot avatars in the narrow sidebar. */
interface GroupRowProps {
  active: boolean
  group: string
  members: GroupMember[]
  needsYou: boolean
  onDisband: (room: { members: GroupMember[]; name: string }) => void
  /** Opens the New section dialog; the group is filed into it on create. */
  onNewSection: (group: string) => void
  onOpen: (group: string) => void
}

export function GroupRow({ active, group, members, needsYou, onOpen, onDisband, onNewSection }: GroupRowProps) {
  const { t } = useI18n()
  const b = useBots()
  const rooms = useValue($groupChats)
  const sections = useValue($botSections)
  const currentSectionId = groupChatSectionId(group, rooms)

  const room = rooms[group] || {
    log: []
  }

  const log = Array.isArray(room.log) ? room.log : []
  const last = log.length ? log[log.length - 1] : null
  const lastAt = groupLastActivity(room)
  // Room previews speak the same handle vocabulary as the roster, mentions
  // and the group prompt: the primary profile is @hermes, not @default.
  const lastFrom = last?.from?.name || ''

  const lastHandle = botHandle(
    lastFrom || 'bot',
    members.find(member => member?.name === lastFrom)
  )

  const preview = last
    ? `${last.from?.kind === 'user' ? b.group.you : `@${lastHandle}`}: ${stripPreviewMarkdown(last.text) || '…'}`
    : b.group.memberCount(members.length)

  const availableMembers = members.filter(member => botSourceStatus(member).available).length
  const availabilityLabel = b.group.availableCount(availableMembers, members.length)

  // Same drag contract as a bot row, under the group's own key shape so a
  // drop zone can tell which kind landed without decoding roster keys.
  const dragKey = groupDragKey(group)
  const dragging = useValue($draggingBot) === dragKey

  const row = (
    <RowButton
      aria-label={`${group}, ${b.group.memberCount(members.length)}, ${availabilityLabel}`}
      className={cn(
        'flex min-h-14 w-full min-w-0 max-w-full items-center gap-3 overflow-hidden rounded-[14px] px-3 py-1.5 text-left transition-colors',
        'hover:bg-[color-mix(in_srgb,var(--bot-row-active,var(--chrome-action-hover))_55%,transparent)]',
        active && 'bg-(--ui-row-active-background) hover:bg-(--ui-row-active-background)',
        dragging && 'opacity-40'
      )}
      draggable
      onClick={() => {
        haptic('tap')
        onOpen(group)
      }}
      onDragEnd={() => $draggingBot.set(null)}
      onDragStart={event => {
        event.dataTransfer.setData(BOT_DRAG_MIME, dragKey)
        event.dataTransfer.effectAllowed = 'move'
        $draggingBot.set(dragKey)
      }}
    >
      <div className="relative flex h-12 w-12 shrink-0 items-center justify-center">
        {room.image ? (
          <img
            alt=""
            className={cn('size-12 rounded-full object-cover', availableMembers === 0 && 'grayscale opacity-60')}
            src={room.image}
          />
        ) : (
          <GroupFaceCluster members={members} muted={availableMembers === 0} />
        )}
        {members.length > 0 && availableMembers < members.length ? (
          <Tip label={availabilityLabel}>
            <span
              aria-label={availabilityLabel}
              className="absolute -bottom-0.5 -right-0.5 flex size-4 items-center justify-center rounded-full bg-(--ui-bg-primary) text-[0.625rem] text-amber-600 ring-1 ring-(--ui-stroke-tertiary) dark:text-amber-300"
            >
              <Codicon name="debug-disconnect" />
            </span>
          </Tip>
        ) : null}
      </div>
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-2">
          <span className="min-w-0 flex-1 truncate text-[0.9375rem] font-medium leading-5 text-foreground">{group}</span>
          {room.pinned ? (
            <Tip label={b.roster.pinned}>
              <Codicon className="shrink-0 text-[0.6875rem] text-(--ui-text-quaternary)" name="pinned" />
            </Tip>
          ) : null}
          {needsYou ? (
            <Tip label={b.group.needsYourInput}>
              <Codicon aria-label={b.roster.needsInput} className="shrink-0 text-(--ui-accent)" name="question" />
            </Tip>
          ) : null}
          {lastAt ? (
            <span className="shrink-0 text-[0.6875rem] text-(--ui-text-quaternary)">
              {rowAge(lastAt, t.sidebar.row)}
            </span>
          ) : null}
        </div>
        <div className="min-w-0 truncate text-[0.8125rem] leading-[18px] text-(--ui-text-tertiary)">{preview}</div>
      </div>
    </RowButton>
  )

  return (
    <ContextMenu>
      <ContextMenuTrigger asChild>{row}</ContextMenuTrigger>
      <ContextMenuContent>
        <ContextMenuItem onSelect={() => onOpen(group)}>{b.canonical.openGroup}</ContextMenuItem>
        <ContextMenuSeparator />
        {/* Same affordance as a bot row's pin; pinned rooms lead the roster
            band, and the flag lives on the room record. */}
        <ContextMenuItem
          onSelect={() => {
            const pinned = toggleGroupChatPinned(group)

            if (pinned !== null) {
              host.notify({ kind: 'info', message: pinned ? b.group.groupPinned(group) : b.group.groupUnpinned(group) })
            }
          }}
        >
          {room.pinned ? b.group.unpinGroup : b.group.pinGroup}
        </ContextMenuItem>
        {/* Filing — the same submenu a bot row gets, driving the room-record
            assignment instead of profile meta. */}
        <ContextMenuSub>
          <ContextMenuSubTrigger>{b.sections.moveTo}</ContextMenuSubTrigger>
          <ContextMenuSubContent>
            {sections.map(section => (
              <ContextMenuItem
                disabled={section.id === currentSectionId}
                key={section.id}
                onSelect={() => moveGroupChatsToSection([group], section.id)}
              >
                <Codicon className="mr-1.5" name="folder" />
                {section.name}
              </ContextMenuItem>
            ))}
            {sections.length ? <ContextMenuSeparator /> : null}
            <ContextMenuItem onSelect={() => onNewSection(group)}>
              <Codicon className="mr-1.5" name="new-folder" />
              {b.sections.newSectionEllipsis}
            </ContextMenuItem>
            {currentSectionId ? (
              <ContextMenuItem onSelect={() => moveGroupChatsToSection([group], null)}>
                <Codicon className="mr-1.5" name="inbox" />
                {b.sections.removeFromSection}
              </ContextMenuItem>
            ) : null}
          </ContextMenuSubContent>
        </ContextMenuSub>
        <ContextMenuSeparator />
        <ContextMenuItem
          className="text-destructive focus:text-destructive"
          onSelect={() =>
            onDisband({
              name: group,
              members
            })
          }
        >
          {b.group.disbandAction}
        </ContextMenuItem>
      </ContextMenuContent>
    </ContextMenu>
  )
}
