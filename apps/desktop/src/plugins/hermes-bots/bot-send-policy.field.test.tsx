import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { useState } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const requestForBot = vi.fn()

vi.mock('./routing', () => ({
  requestForBot: (...args: unknown[]) => requestForBot(...args),
  resolveBotConnectionRoute: () => ({ route: { profile: 'scribe', targetProfile: 'scribe' } })
}))

vi.mock('./data', () => ({ botSelectionKey: (bot: { name: string }) => bot.name }))

vi.mock('@hermes/plugin-sdk', () => ({
  Checkbox: ({ checked, onCheckedChange }: { checked: boolean; onCheckedChange: (value: boolean) => void }) => (
    <input
      checked={checked}
      onChange={event => onCheckedChange(event.target.checked)}
      role="checkbox"
      type="checkbox"
    />
  ),
  host: { notifyError: vi.fn() }
}))

vi.mock('./i18n', () => ({
  botsText: () => ({ bot: {} }),
  useBots: () => ({ bot: { sendWithoutAsking: 'Send without asking', sendWithoutAskingHint: 'hint' } })
}))

import { emptySendPolicy, SendPolicyField, type SendPolicyState } from './bot-send-policy'
import type { RosterRow } from './types'

let latest: SendPolicyState = emptySendPolicy()

function Harness({ bot }: { bot: RosterRow }) {
  const [state, setState] = useState(emptySendPolicy)

  latest = state

  return <SendPolicyField bot={bot} setState={setState} state={state} />
}

const rowFor = () => ({ name: 'scribe' }) as RosterRow

beforeEach(() => {
  requestForBot.mockReset()
  latest = emptySendPolicy()
})

afterEach(cleanup)

describe('SendPolicyField', () => {
  it('keeps the unsaved toggle and does not refetch when the roster hands back a new object for the same bot', async () => {
    requestForBot.mockResolvedValue({ value: true })

    const view = render(<Harness bot={rowFor()} />)

    await waitFor(() => expect(latest.loaded).toBe(true))
    fireEvent.click(screen.getByRole('checkbox'))
    expect(latest).toMatchObject({ ask: false, dirty: true })

    view.rerender(<Harness bot={rowFor()} />)
    await act(async () => undefined)

    expect(requestForBot).toHaveBeenCalledTimes(1)
    expect(latest).toMatchObject({ ask: false, dirty: true })
  })

  it('ignores a late reply once the owner has changed the toggle', async () => {
    requestForBot.mockResolvedValueOnce({ value: true })

    const view = render(<Harness bot={rowFor()} />)

    await waitFor(() => expect(latest.loaded).toBe(true))

    let reply!: (value: unknown) => void

    requestForBot.mockReturnValueOnce(
      new Promise(resolve => {
        reply = resolve
      })
    )

    view.rerender(<Harness bot={{ name: 'other' } as RosterRow} />)
    fireEvent.click(screen.getByRole('checkbox'))

    await act(async () => {
      reply({ value: true })
    })

    expect(requestForBot).toHaveBeenCalledTimes(2)
    expect(latest).toMatchObject({ ask: false, dirty: true })
  })
})
