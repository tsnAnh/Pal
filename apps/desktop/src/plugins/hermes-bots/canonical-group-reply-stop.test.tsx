import { useStore } from '@nanostores/react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { atom } from 'nanostores'
import type { ComponentProps, ReactNode } from 'react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'

const request = vi.hoisted(() => vi.fn())
vi.mock('@hermes/plugin-sdk', async () => {
  const { pluginSdkMock, createGroupGateway } = await import('./group-test-utils')
  const gateway = createGroupGateway()
  const { en } = await import('@/i18n/en')
  const { CANONICAL_GROUP_LOCALES } = await import('./canonical-group-locales')
  const { ConfirmDialog } = await import('@/components/ui/confirm-dialog')

  return { ...await pluginSdkMock(gateway.host), atom, useValue: useStore, ConfirmDialog,
    useI18n: () => ({ t: en }),
    usePluginI18n: () => (key: string) => CANONICAL_GROUP_LOCALES.en[key.replace('canonical.', '') as keyof typeof CANONICAL_GROUP_LOCALES.en] ?? key,
    Button: (p: ComponentProps<'button'>) => <button {...p} />,
    Input: (p: ComponentProps<'input'>) => <input {...p} />,
    RowButton: (p: ComponentProps<'button'>) => <button type="button" {...p} />,
    Codicon: () => null,
    Tip: ({ children }: { children: ReactNode }) => children,
    host: { ...gateway.host, requestProfile: request } }
})

import { CanonicalGroupWorkspace } from './canonical-group-workspace'

const originalDesktop = window.hermesDesktop
beforeEach(() => { Object.defineProperty(window, 'hermesDesktop', { configurable: true, writable: true, value: undefined }) })
afterEach(() => { cleanup(); request.mockReset(); localStorage.clear(); window.hermesDesktop = originalDesktop })

const members = [
  { member_id: 'ada', profile: 'ada', handle: 'ada', display_name: 'Ada' },
  { member_id: 'bo', profile: 'bo', handle: 'bo', display_name: 'Bo' }
]

const memberMessage = {
  seq: 1, kind: 'message.member', event_id: 'dmessage:one', room_id: 'room',
  actor: { kind: 'member', id: 'ada', display_name: 'Ada' }, payload: { text: 'We ship\n on Friday', member_id: 'ada' }
}

function serve({ features = ['reply_to'], driver = {}, events = [memberMessage] }: {
  features?: string[]; driver?: Record<string, unknown>; events?: unknown[]
} = {}) {
  request.mockImplementation(async (_route, method) => {
    if (method === 'groups.capabilities') {return { features }}

    if (method === 'groups.state') {return { room: { name: 'Room', members }, driver_status: driver }}

    if (method === 'groups.log') {return { events, has_more: false }}

    return {}
  })
}

const binding = { connectionId: 'local', profile: 'team', roomId: 'room' }

async function openRoom() {
  const view = render(<CanonicalGroupWorkspace binding={binding} />)
  await waitFor(() => expect((screen.getByRole('textbox') as HTMLTextAreaElement).disabled).toBe(false))

  return view.container
}

it('replies to a bot message: chip, addressed send with a short quote, dismissible', async () => {
  serve()
  const container = await openRoom()
  fireEvent.click(await screen.findByRole('button', { name: 'Reply' }))

  const chip = container.querySelector('[data-slot="group-reply-chip"]') as HTMLElement
  expect(chip.textContent).toContain('Replying to Ada')
  expect(chip.textContent).toContain('We ship on Friday')

  fireEvent.click(screen.getByRole('button', { name: 'Cancel reply' }))
  expect(container.querySelector('[data-slot="group-reply-chip"]')).toBeNull()

  fireEvent.click(screen.getByRole('button', { name: 'Reply' }))
  fireEvent.change(screen.getByRole('textbox'), { target: { value: 'why Friday?' } })
  fireEvent.click(screen.getByRole('button', { name: 'Send' }))

  await waitFor(() => expect(request.mock.calls.some(c => c[1] === 'groups.send')).toBe(true))
  const send = request.mock.calls.find(c => c[1] === 'groups.send')!
  expect(send[2].payload).toMatchObject({
    text: 'why Friday?', reply_to: { event_id: 'dmessage:one', member_id: 'ada', quote: 'We ship on Friday' }
  })
  await waitFor(() => expect(container.querySelector('[data-slot="group-reply-chip"]')).toBeNull())
})

it('sends without a reference once the chip is dismissed', async () => {
  serve()
  await openRoom()
  fireEvent.click(await screen.findByRole('button', { name: 'Reply' }))
  fireEvent.click(screen.getByRole('button', { name: 'Cancel reply' }))
  fireEvent.change(screen.getByRole('textbox'), { target: { value: 'hello all' } })
  fireEvent.click(screen.getByRole('button', { name: 'Send' }))

  await waitFor(() => expect(request.mock.calls.some(c => c[1] === 'groups.send')).toBe(true))
  expect(request.mock.calls.find(c => c[1] === 'groups.send')![2].payload).not.toHaveProperty('reply_to')
})

it('offers no Reply on a gateway that predates reply_to', async () => {
  serve({ features: [] })
  await openRoom()
  await waitFor(() => expect(request.mock.calls.some(c => c[1] === 'groups.log')).toBe(true))
  expect((await screen.findAllByText('Ada')).length).toBeGreaterThan(1)
  expect(screen.queryByRole('button', { name: 'Reply' })).toBeNull()
})

it('shows a quote chip on the stored reply and Stopped on a cut-off turn', async () => {
  serve({ events: [
    memberMessage,
    { seq: 2, kind: 'message.user', event_id: 'user:1', payload: { text: 'why Friday?', reply_to: { event_id: 'dmessage:one', member_id: 'ada', quote: 'We ship on Friday' } } },
    { seq: 3, kind: 'turn.cancelled', payload: { member_id: 'bo', reason: 'room-stopped' } }
  ] })
  const container = await openRoom()

  expect(container.querySelector('[data-slot="group-reply-quote"]')?.textContent).toContain('Replying to Ada')
  expect(screen.getByText('Stopped')).toBeTruthy()
})

it('shows Stop now only while a member works, and stops the room', async () => {
  serve()
  const idle = render(<CanonicalGroupWorkspace binding={binding} />)
  await screen.findByText('Room')
  expect(screen.queryByRole('button', { name: 'Stop now' })).toBeNull()
  idle.unmount()

  serve({ driver: { working: true, member_activity: [{ member_id: 'bo', status: 'running' }] } })
  render(<CanonicalGroupWorkspace binding={{ ...binding, roomId: 'busy' }} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Stop now' }))

  await waitFor(() => expect(request.mock.calls.some(c => c[1] === 'groups.stop')).toBe(true))
  expect(request.mock.calls.find(c => c[1] === 'groups.stop')![2]).toMatchObject({ room_id: 'busy' })
})

it('offers @everyone while composing in a room', async () => {
  serve()
  await openRoom()
  const box = screen.getByRole('textbox') as HTMLTextAreaElement
  fireEvent.change(box, { target: { value: '@eve', selectionStart: 4, selectionEnd: 4 } })
  box.setSelectionRange(4, 4)
  fireEvent.keyUp(box)

  expect(await screen.findByText('@everyone')).toBeTruthy()
})
