import { useStore } from '@nanostores/react'
import { useQueries } from '@tanstack/react-query'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { useLocation, useNavigate } from 'react-router'

import type { HermesGateway, ProfileScope } from '@/hermes'
import { profileScopeKey } from '@/hermes'
import { useI18n } from '@/i18n'
import { completeMcpDesktopOAuth } from '@/lib/mcp-dashboard-oauth'
import { queryClient } from '@/lib/query-client'
import { notifyError } from '@/store/notifications'

import { CAPABILITIES_ROUTE } from '../../../routes'
import { installBundledEntry } from '../../mcp/install-catalog-entry'
import { useMcpServers } from '../../mcp/use-mcp-servers'
import { $abandonedConnects } from '../data/account-operations'
import { useHostedActions } from '../data/hosted-actions'
import { joinBundledEntries, joinLocalServers } from '../data/join'
import { CONNECTORS_QUERY_ROOT } from '../data/keys'
import { useHostedConnectors } from '../data/queries'
import { deriveCards, forgetAbandoned, localServerName } from '../derive'
import type { HostedPhase } from '../types'

import {
  type AppBot,
  appRefOf,
  type BotAccess,
  botAccessFor,
  BotAppError,
  type BotAppFailure,
  type BotAppsState,
  botsUsing,
  readBotAppsState,
  setBotAccess
} from './bot-access'
import { type AppEntry, type AppsCatalog, buildAppsCatalog } from './catalog'

const BOT_STATE_STALE_MS = 30_000

const botStateKey = (scope: ProfileScope) => [CONNECTORS_QUERY_ROOT, profileScopeKey(scope), 'bot-apps'] as const

export interface UseConnectorAppsOptions {
  bots: readonly AppBot[]
  gateway: HermesGateway | null
  profile: ProfileScope
}

export interface ConnectorAppsView {
  access: (app: AppEntry, bot: AppBot) => BotAccess
  busyId: null | string
  catalog: AppsCatalog
  connect: (app: AppEntry) => void
  failed: boolean
  loading: boolean
  openInSettings: (app: AppEntry) => void
  phase: HostedPhase
  refetch: () => void
  setAccess: (app: AppEntry, bot: AppBot, enabled: boolean) => Promise<BotAppFailure | null>
  signInBot: (app: AppEntry, bot: AppBot) => Promise<void>
  usedBy: (app: AppEntry) => AppBot[]
}

export function useConnectorApps({ bots, gateway, profile }: UseConnectorAppsOptions): ConnectorAppsView {
  const { t } = useI18n()
  const navigate = useNavigate()
  const location = useLocation()
  const hosted = useHostedConnectors(profile)
  const mcp = useMcpServers({ gateway, profile })
  const abandoned = useStore($abandonedConnects)
  const [installing, setInstalling] = useState<null | string>(null)
  const [authAfterInstall, setAuthAfterInstall] = useState<null | string>(null)

  const hostedActions = useHostedActions(profile, hosted.accounts, {
    returnRoute: `${location.pathname}${location.search}`
  })

  const local = useMemo(
    () =>
      joinLocalServers({
        catalog: mcp.catalog,
        servers: mcp.servers,
        status: mcp.statuses,
        toolCounts: mcp.toolCounts,
        usage: mcp.usageByServer
      }),
    [mcp.catalog, mcp.servers, mcp.statuses, mcp.toolCounts, mcp.usageByServer]
  )

  const bundled = useMemo(() => joinBundledEntries(mcp.availableCatalog), [mcp.availableCatalog])

  const cards = useMemo(
    () =>
      deriveCards({
        bundled,
        hosted: forgetAbandoned(hosted.rows, new Set(abandoned)),
        local,
        titles: hosted.titles
      }),
    [abandoned, bundled, hosted.rows, hosted.titles, local]
  )

  const loading = hosted.phase === 'loading' || mcp.configLoading || mcp.catalogLoading
  const catalogReady = !mcp.configLoading && !mcp.catalogLoading

  const catalog = useMemo(
    () => buildAppsCatalog({ cards, catalogReady, phase: hosted.phase }),
    [cards, catalogReady, hosted.phase]
  )

  const botStates = useQueries({
    queries: bots.map(bot => ({
      queryFn: () => readBotAppsState(bot.scope),
      queryKey: botStateKey(bot.scope),
      retry: false,
      staleTime: BOT_STATE_STALE_MS
    }))
  })

  const statesById = useMemo(() => {
    const states: Record<string, BotAppsState | undefined> = {}

    bots.forEach((bot, index) => {
      states[bot.id] = botStates[index]?.data
    })

    return states
  }, [botStates, bots])

  useEffect(() => {
    if (authAfterInstall && mcp.servers[authAfterInstall]) {
      setAuthAfterInstall(null)
      void mcp.authenticate(authAfterInstall)
    }
  }, [authAfterInstall, mcp])

  const install = useCallback(
    async (app: AppEntry) => {
      const entry = mcp.availableCatalog.find(candidate => candidate.name === app.card?.ways.local?.entryName)

      if (!entry) {
        return
      }

      setInstalling(app.id)

      try {
        await installBundledEntry(entry, {}, profile)
        await mcp.onCatalogInstalled()

        if (entry.auth_type === 'oauth') {
          setAuthAfterInstall(entry.name)
        }
      } catch (error) {
        notifyError(error, t.settings.mcp.catalogInstallFailed(app.name))
      } finally {
        setInstalling(null)
      }
    },
    [mcp, profile, t]
  )

  const connect = (app: AppEntry) => {
    const card = app.card

    if (!card || hostedActions.runHostedVerb(card)) {
      return
    }

    if (card.verb === 'authenticate') {
      void mcp.authenticate(localServerName(card))
    } else if (card.verb === 'install') {
      void install(app)
    }
  }

  const openInSettings = (app: AppEntry) => {
    const card = app.card

    if (!card) {
      return
    }

    const param = card.ways.hosted ? 'connector' : 'server'

    navigate(`${CAPABILITIES_ROUTE}?tab=connectors&${param}=${encodeURIComponent(card.slug)}`)
  }

  const access = (app: AppEntry, bot: AppBot): BotAccess => {
    const state = statesById[bot.id]

    return app.card && state ? botAccessFor(state, appRefOf(app.card)) : 'unknown'
  }

  const usedBy = (app: AppEntry): AppBot[] => (app.card ? botsUsing(appRefOf(app.card), bots, statesById) : [])

  const setAccess = async (app: AppEntry, bot: AppBot, enabled: boolean): Promise<BotAppFailure | null> => {
    if (!app.card) {
      return 'failed'
    }

    const ref = appRefOf(app.card)
    const entry = ref.kind === 'local' ? (mcp.catalog.find(candidate => candidate.name === ref.name) ?? null) : null

    try {
      await setBotAccess(bot.scope, ref, enabled, entry)

      return null
    } catch (error) {
      return error instanceof BotAppError ? error.kind : 'failed'
    } finally {
      void queryClient.invalidateQueries({ queryKey: botStateKey(bot.scope) })
    }
  }

  const signInBot = async (app: AppEntry, bot: AppBot): Promise<void> => {
    if (!app.card) {
      return
    }

    const ref = appRefOf(app.card)

    if (ref.kind !== 'local') {
      return
    }

    try {
      await completeMcpDesktopOAuth({ cancelled: () => false, profile: bot.scope, serverName: ref.name })
    } catch (error) {
      notifyError(error, app.name)
    } finally {
      void queryClient.invalidateQueries({ queryKey: botStateKey(bot.scope) })
    }
  }

  const busySlug = hostedActions.busySlug

  return {
    access,
    busyId: installing ?? busySlug ?? mcp.authing,
    catalog,
    connect,
    failed: hosted.phase === 'failed',
    loading: loading && cards.length === 0,
    openInSettings,
    phase: hosted.phase,
    refetch: hosted.refetch,
    setAccess,
    signInBot,
    usedBy
  }
}
