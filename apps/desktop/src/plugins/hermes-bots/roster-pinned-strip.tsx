import type { ReactNode } from 'react'

import { botRosterKey } from './data'
import type { RosterRow } from './types'

interface PinnedBotRow {
  bot: RosterRow
  kind: 'bot'
  pinned: boolean
}

export function isPinnedBotRow<T extends { kind?: string }>(row: T): row is Extract<T, PinnedBotRow> {
  return row.kind === 'bot' && Boolean((row as Partial<PinnedBotRow>).pinned)
}

export function pinnedBots<T extends { kind?: string }>(rows: T[]): RosterRow[] {
  return rows.filter(isPinnedBotRow).map(row => row.bot)
}

interface PinnedStripProps {
  bots: RosterRow[]
  renderTile: (bot: RosterRow) => ReactNode
}

export function PinnedStrip({ bots, renderTile }: PinnedStripProps) {
  if (!bots.length) {
    return null
  }

  return (
    <div
      className="flex max-h-60 shrink-0 flex-wrap justify-start gap-y-2 overflow-y-auto overscroll-contain px-[14px] pb-4 pt-1"
      data-slot="bots-pinned-strip"
    >
      {bots.map(bot => (
        <div key={botRosterKey(bot)}>{renderTile(bot)}</div>
      ))}
    </div>
  )
}
