import { describe, expect, it, vi } from 'vitest'

import { mergeMultiSourceRoster } from './data'
import { rosterGatewayOptions, rosterGatewaySections } from './roster-sections'
import type { RosterRow } from './types'

vi.mock('@hermes/plugin-sdk', async () => {
  const { atom } = await import('nanostores')

  return { atom, host: {}, queryClient: undefined, useQuery: vi.fn(), useValue: vi.fn() }
})

vi.mock('./shared', () => ({ getPluginCtx: () => null, ID: 'hermes-bots' }))

const sources = [
  { connectionId: 'local', kind: 'local', label: 'This device', reachable: true },
  { connectionId: 'pi', kind: 'ssh', label: 'Raspberry Pi', reachable: true }
]

const piAgent = (profile: string) => ({
  connectionId: 'pi',
  connectionKind: 'ssh',
  connectionLabel: 'Raspberry Pi',
  handle: profile,
  profile,
  targetProfile: profile
})

const staleUnion = { agents: [piAgent('default'), piAgent('dr-eggbot')], primaryConnectionId: 'pi', sources }

describe('a bot the active gateway lists before the union roster catches up', () => {
  const live = { profiles: [{ name: 'default' }, { name: 'dr-eggbot' }, { name: 'fork-sync' }] }

  it('belongs to the active connection, with a route to it', () => {
    const rows = mergeMultiSourceRoster(live, staleUnion, 'pi').profiles as RosterRow[]
    const born = rows.find(row => row.name === 'fork-sync')

    expect(rows.map(row => row.name)).toEqual(['default', 'dr-eggbot', 'fork-sync'])
    expect(born).toMatchObject({
      connectionId: 'pi',
      connectionKind: 'ssh',
      connectionLabel: 'Raspberry Pi',
      route: { connectionId: 'pi', mode: 'remote', profile: 'fork-sync', targetProfile: 'fork-sync' }
    })
  })

  it('is listed under its own gateway, never under a "Current gateway" heading', () => {
    const rows = mergeMultiSourceRoster(live, staleUnion, 'pi').profiles as RosterRow[]
    const options = rosterGatewayOptions(sources, rows)
    const { sections } = rosterGatewaySections(rows, [...options, { connectionId: 'local', count: 1 }])

    expect(sections.map(section => [section.id, section.rows.map(row => row.name)])).toEqual([
      ['pi', ['default', 'dr-eggbot', 'fork-sync']]
    ])
  })

  it('leaves a window on the unscoped local backend as it was', () => {
    const rows = mergeMultiSourceRoster(live, { agents: [], sources }, '').profiles as RosterRow[]

    expect(rows.map(row => [row.name, row.connectionId])).toEqual([
      ['default', undefined],
      ['dr-eggbot', undefined],
      ['fork-sync', undefined]
    ])
  })
})
