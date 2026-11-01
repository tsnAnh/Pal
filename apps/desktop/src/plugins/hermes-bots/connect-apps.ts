import * as sdk from '@hermes/plugin-sdk'
import { atom } from '@hermes/plugin-sdk'
import type { AppBot } from '@hermes/plugin-sdk'

import { displayName } from './labels'
import { botBackendProfileScope, botConnectionRoute } from './routing'
import type { RosterRow } from './types'

export const connectAppsSupported = 'useConnectorApps' in sdk && typeof sdk.useConnectorApps === 'function'

export interface ConnectAppsRequest {
  botId: null | string
  open: boolean
}

export const $connectApps = atom<ConnectAppsRequest>({ botId: null, open: false })

export const openConnectApps = (bot?: Pick<RosterRow, 'connectionId' | 'name'>) =>
  $connectApps.set({ botId: bot ? connectAppsBotId(bot) : null, open: true })

export const closeConnectApps = () => $connectApps.set({ botId: null, open: false })

export const connectAppsBotId = (bot: Pick<RosterRow, 'connectionId' | 'name'>) =>
  `${bot.connectionId ?? ''}::${bot.name}`

export function appBotOf(row: RosterRow): AppBot {
  return {
    id: connectAppsBotId(row),
    label: displayName(row),
    scope: botBackendProfileScope(botConnectionRoute(row), row.name)
  }
}

export function appBotsOf(roster: readonly RosterRow[]): AppBot[] {
  return roster.filter(row => !row.ghost && !row.unserved && !row.sourceMissing).map(appBotOf)
}
