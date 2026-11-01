import {
  Codicon,
  ContextMenuItem,
  ContextMenuSub,
  ContextMenuSubContent,
  ContextMenuSubTrigger,
  host
} from '@hermes/plugin-sdk'

import { exportBotTemplate, templateFailure } from './bot-template'
import { $botMeta } from './data'
import { botsText, useBots } from './i18n'
import { displayName } from './labels'
import { botRosterMeta } from './routing'
import type { RosterRow } from './types'

export async function runBotTemplateExport(bot: RosterRow): Promise<void> {
  const copy = botsText().template

  try {
    if ((await exportBotTemplate(bot)) === 'saved') {
      host.notify({ kind: 'success', message: copy.exportDone(displayName(bot, botRosterMeta(bot, $botMeta.get()))) })
    }
  } catch (error) {
    if (templateFailure(error) === 'unsupported') {
      host.notify({ kind: 'error', message: copy.exportNeedsUpdate })
    } else {
      host.notifyError?.(error, copy.exportFailed)
    }
  }
}

export function BotShareSubmenu({ bot }: { bot: RosterRow }) {
  const b = useBots()

  return (
    <ContextMenuSub>
      <ContextMenuSubTrigger>{b.template.share}</ContextMenuSubTrigger>
      <ContextMenuSubContent>
        <ContextMenuItem onSelect={() => void runBotTemplateExport(bot)}>
          <Codicon className="mr-1.5" name="export" />
          {b.template.exportAction}
        </ContextMenuItem>
      </ContextMenuSubContent>
    </ContextMenuSub>
  )
}
