import type { ReactNode } from 'react'

import { Slot as ContribSlot } from '@/contrib/react/slot'
import { cn } from '@/lib/utils'

import { COMPOSER_AREAS } from './contrib'

const BOT_GRID =
  'grid-cols-[minmax(0,1fr)_auto_auto_auto] items-center gap-x-(--composer-control-gap) gap-y-(--composer-row-gap) [grid-template-areas:"input_input_input_input"_"chips_menu_contrib_actions"]'

const SINGLE_COLUMN_GRID =
  'grid-cols-[minmax(0,1fr)] gap-(--composer-row-gap) [grid-template-areas:"input"_"menu"_"controls"]'

const STACKED_GRID = 'grid-cols-[auto_1fr] gap-(--composer-row-gap) [grid-template-areas:"input_input"_"menu_controls"]'

const INLINE_GRID =
  'grid-cols-[auto_1fr_auto] items-center gap-(--composer-control-gap) [grid-template-areas:"menu_input_controls"]'

/** Grid areas for the menu / input / controls row: one row when roomy, input
 *  above menu + controls when stacked, one area per row once two touch-size
 *  controls no longer fit side by side, and in a bot chat the card layout
 *  (input on top, model chips left, attach + send right). */
function gridClass(singleColumn: boolean, stacked: boolean, botGrid: boolean): string {
  if (botGrid) {
    return BOT_GRID
  }

  if (singleColumn) {
    return SINGLE_COLUMN_GRID
  }

  return stacked ? STACKED_GRID : INLINE_GRID
}

export function ComposerControlRow({
  botChat,
  contextMenu,
  controls,
  input,
  singleColumn,
  stacked
}: {
  botChat: boolean
  contextMenu: ReactNode
  controls: ReactNode
  input: ReactNode
  singleColumn: boolean
  stacked: boolean
}) {
  const botGrid = botChat && !singleColumn

  return (
    <div className={cn('grid w-full', gridClass(singleColumn, stacked, botGrid))}>
      <div
        className={cn(
          'flex items-start gap-(--composer-control-gap) [grid-area:menu]',
          botGrid ? 'items-center self-center' : 'translate-y-[3px] self-start'
        )}
      >
        {contextMenu}
        <ContribSlot area={COMPOSER_AREAS.leading} />
      </div>
      <div className="min-w-0 [grid-area:input]">{input}</div>
      {/* `justify-end` packs contributed actions and the send cluster
        together on the right. The cluster must not carry its own
        `ml-auto`: in the stacked layout the auto margin absorbs the
        row's free space and pins a contributed action to the row
        start, detached from the cluster (#116332). */}
      <div
        className={cn(
          botGrid
            ? 'contents'
            : 'flex min-w-0 items-center justify-end gap-(--composer-control-gap) [grid-area:controls]'
        )}
      >
        {botGrid ? (
          <div className="flex items-center gap-(--composer-control-gap) [grid-area:contrib] empty:hidden">
            <ContribSlot area={COMPOSER_AREAS.actions} />
          </div>
        ) : (
          <ContribSlot area={COMPOSER_AREAS.actions} />
        )}
        {controls}
      </div>
    </div>
  )
}
