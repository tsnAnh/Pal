import { Button, Codicon, Tip } from '@hermes/plugin-sdk'
import type { ComponentProps } from 'react'

import { GroupRow } from './bot-row'
import { $botMeta } from './data'
import { $groupChats, updateGroupChat } from './group-chat'
import type { $groupClarify, $groupNeedsYou } from './group-chat'
import { groupChatNames, groupLastActivity } from './group-membership'
import { reorderGroupRows, sortGroupRosterRows } from './group-order'
import { groupHasPendingClarify } from './group-turns'
import type { useBots } from './i18n'
import type { RosterGroupRow } from './roster-pane-derivation'

interface RosterGroupRowViewProps extends Omit<ComponentProps<typeof GroupRow>, 'needsYou'> {
  b: ReturnType<typeof useBots>
  groupClarify: ReturnType<typeof $groupClarify.get>
  groupNeedsYou: ReturnType<typeof $groupNeedsYou.get>
  groupRooms: ReturnType<typeof $groupChats.get>
  sortedGroupRows: RosterGroupRow[]
}

export function RosterGroupRowView({
  b,
  groupClarify,
  groupNeedsYou,
  groupRooms,
  sortedGroupRows,
  ...rowProps
}: RosterGroupRowViewProps) {
  const moveRoom = (name: string, delta: -1 | 1) => {
    // Read at the gesture, not the last render: a sync or disband may have
    // replaced this room in the meantime. Ordering never writes bot metadata.
    const current = $groupChats.get()

    if (current[name]?.roomId !== groupRooms[name]?.roomId || current[name]?.tombstone) {
      return
    }

    const rows = groupChatNames($botMeta.get(), current).map(name => ({
      kind: 'group' as const,
      name,
      pinned: Boolean(current[name]?.pinned),
      activity: groupLastActivity(current[name])
    }))

    const order = reorderGroupRows(
      sortGroupRosterRows(rows, current),
      name,
      delta,
      sortedGroupRows.map(row => row.name)
    )

    order?.forEach((name, rosterOrder) => {
      updateGroupChat(name, room => ({ ...room, rosterOrder }), { sync: false })
    })
  }

  return (
    <div className="group/group-row relative grid min-w-0 grid-cols-[minmax(0,1fr)] items-center">
      <GroupRow
        {...rowProps}
        needsYou={Boolean(groupNeedsYou[rowProps.group]) || groupHasPendingClarify(groupClarify, rowProps.group)}
      />
      <div className="absolute right-1 top-1/2 flex -translate-y-1/2 flex-col opacity-0 transition-opacity focus-within:opacity-100 group-hover/group-row:opacity-100">
        {([-1, 1] as const).map(delta => (
          <Tip key={delta} label={delta === -1 ? b.sections.moveUp : b.sections.moveDown}>
            <Button
              aria-label={`${rowProps.group}: ${delta === -1 ? b.sections.moveUp : b.sections.moveDown}`}
              disabled={!reorderGroupRows(sortedGroupRows, rowProps.group, delta)}
              onClick={() => moveRoom(rowProps.group, delta)}
              size="icon-xs"
              variant="ghost"
            >
              <Codicon name={delta === -1 ? 'chevron-up' : 'chevron-down'} />
            </Button>
          </Tip>
        ))}
      </div>
    </div>
  )
}
