import { AssistantRuntimeProvider, type ThreadMessage, useExternalStoreRuntime } from '@assistant-ui/react'
import { act, cleanup, fireEvent, render as renderUi, screen, waitFor, within } from '@testing-library/react'
import type { ReactNode } from 'react'
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'

import type { HermesGateway } from '@/hermes'
import { handleApprovalKey, releaseApprovalKey } from '@/lib/keybinds/approval-keys'
import { parseApprovalDraft } from '@/store/approval-draft'
import { $gateway } from '@/store/gateway'
import {
  APPROVAL_RESPOND_REQUEST_TIMEOUT_MS,
  clearAllPrompts,
  sessionApprovalRequests,
  setApprovalRequest
} from '@/store/prompts'
import { rememberServerRequest, resetServerRequestsForTests } from '@/store/server-requests'
import { $activeSessionId } from '@/store/session'
import { stubMenuDomApis, stubResizeObserver } from '@/test/jsdom'

import { PendingApprovalStack } from './approval'

function Runtime({ children }: { children: ReactNode }) {
  const runtime = useExternalStoreRuntime<ThreadMessage>({ messages: [], isRunning: false, onNew: async () => {} })

  return <AssistantRuntimeProvider runtime={runtime}>{children}</AssistantRuntimeProvider>
}

const render = (children: ReactNode) => renderUi(<Runtime>{children}</Runtime>)

beforeAll(() => {
  stubMenuDomApis()
  stubResizeObserver()
})

beforeEach(() => resetServerRequestsForTests())

afterEach(() => {
  cleanup()
  releaseApprovalKey()
  clearAllPrompts()
  resetServerRequestsForTests()
  $activeSessionId.set(null)
  $gateway.set(null)
})

const DRAFT = {
  channel: 'Gmail',
  editable: true,
  held: false,
  kind: 'outbound_message',
  recipient: 'ada@example.com',
  subject: 'Lunch',
  text: 'Lunch at noon?'
}

function setDraft(extra: Record<string, unknown> = {}, request: { serverRequestId?: string } = {}) {
  $activeSessionId.set('sess-1')
  setApprovalRequest({
    choices: ['once', 'deny'],
    command: DRAFT.text,
    description: 'Send to ada@example.com via Gmail',
    draft: parseApprovalDraft({ ...DRAFT, ...extra }),
    requestId: 'draft-1',
    sessionId: 'sess-1',
    ...request
  })
}

function liveApproval(id = 'srq-draft') {
  const respond = vi.fn()
  rememberServerRequest({ fail: vi.fn(), id, method: 'approval', params: {}, respond })

  return respond
}

function mockGateway() {
  const request = vi.fn().mockResolvedValue({ resolved: 1 })
  $gateway.set({ request } as unknown as HermesGateway)

  return request
}

describe('outbound draft card', () => {
  it('shows the recipient, channel, subject and the whole text with Send, Edit and Discard', () => {
    setDraft()
    render(<PendingApprovalStack />)

    expect(screen.getByText('To ada@example.com · via Gmail')).toBeTruthy()
    expect(screen.getByText('Subject: Lunch')).toBeTruthy()
    expect(screen.getByText('Lunch at noon?')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Send' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Edit' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Discard' })).toBeTruthy()
    expect(screen.queryByRole('button', { name: /Run|Reject|Always/ })).toBeNull()
  })

  it('lists every detail beside the text', () => {
    setDraft()
    $activeSessionId.set('sess-1')
    const request = sessionApprovalRequests('sess-1').get()[0]
    setApprovalRequest({
      ...request,
      draft: parseApprovalDraft(DRAFT, {
        details: [
          { name: 'Cc', value: 'bob@example.com' },
          { name: 'Attachments', value: 'plan.pdf (12 KB)' }
        ]
      })
    })
    render(<PendingApprovalStack />)

    expect(screen.getByText('Cc')).toBeTruthy()
    expect(screen.getByText('bob@example.com')).toBeTruthy()
    expect(screen.getByText('plan.pdf (12 KB)')).toBeTruthy()
  })

  it('renders without a details list when the gateway sends none', () => {
    setDraft()
    const { container } = render(<PendingApprovalStack />)

    expect(container.querySelector('[data-slot="tool-draft-details"]')).toBeNull()
    expect(screen.getByRole('button', { name: 'Send' })).toBeTruthy()
  })

  it('offers only Discard with an explanation when the draft cannot be shown in full', () => {
    setDraft()
    const request = sessionApprovalRequests('sess-1').get()[0]
    setApprovalRequest({ ...request, draft: parseApprovalDraft(DRAFT, { choices: ['deny'] }) })
    render(<PendingApprovalStack />)

    expect(screen.getByRole('button', { name: 'Discard' })).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Send' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Edit' })).toBeNull()
    expect(screen.getByText(/can only be discarded/)).toBeTruthy()
  })

  it('answers a live draft with once on Send and deny on Discard', async () => {
    const respond = liveApproval()
    mockGateway()
    setDraft({}, { serverRequestId: 'srq-draft' })
    render(<PendingApprovalStack />)

    fireEvent.click(screen.getByRole('button', { name: 'Send' }))

    await waitFor(() => expect(respond).toHaveBeenCalledWith({ choice: 'once' }))
    expect(sessionApprovalRequests('sess-1').get()).toHaveLength(0)
  })

  it('discards through the queue RPC when the draft has no live request', async () => {
    const request = mockGateway()
    setDraft()
    render(<PendingApprovalStack />)

    fireEvent.click(screen.getByRole('button', { name: 'Discard' }))

    await waitFor(() =>
      expect(request).toHaveBeenCalledWith(
        'approval.respond',
        { all: false, choice: 'deny', request_id: 'draft-1', session_id: 'sess-1' },
        APPROVAL_RESPOND_REQUEST_TIMEOUT_MS,
        undefined
      )
    )
  })

  it('sends the edited text with the answer and says so on the button', async () => {
    const respond = liveApproval()
    mockGateway()
    setDraft({}, { serverRequestId: 'srq-draft' })
    render(<PendingApprovalStack />)

    fireEvent.click(screen.getByRole('button', { name: 'Edit' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Edit message' }), { target: { value: 'Lunch at one?' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send edited' }))

    await waitFor(() => expect(respond).toHaveBeenCalledWith({ choice: 'once', edited_text: 'Lunch at one?' }))
  })

  it('will not send an emptied edit', () => {
    mockGateway()
    setDraft()
    render(<PendingApprovalStack />)

    fireEvent.click(screen.getByRole('button', { name: 'Edit' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Edit message' }), { target: { value: '   ' } })

    expect((screen.getByRole('button', { name: /Send/ }) as HTMLButtonElement).disabled).toBe(true)
  })

  it('cancelling an edit restores the original text and plain Send', () => {
    setDraft()
    render(<PendingApprovalStack />)

    fireEvent.click(screen.getByRole('button', { name: 'Edit' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Edit message' }), { target: { value: 'changed' } })
    fireEvent.click(screen.getByRole('button', { name: 'Cancel edit' }))

    expect(screen.getByText('Lunch at noon?')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Send' })).toBeTruthy()
  })

  it('shows replayed draft text when the card is not being edited', () => {
    setDraft()
    render(<PendingApprovalStack />)
    expect(screen.getByText('Lunch at noon?')).toBeTruthy()

    act(() => setDraft({ text: 'Lunch at one?' }))

    expect(screen.getByText('Lunch at one?')).toBeTruthy()
  })

  it('refreshes an untouched editor to replayed draft text', () => {
    setDraft()
    render(<PendingApprovalStack />)

    fireEvent.click(screen.getByRole('button', { name: 'Edit' }))
    act(() => setDraft({ text: 'Lunch at one?' }))

    expect((screen.getByRole('textbox', { name: 'Edit message' }) as HTMLTextAreaElement).value).toBe('Lunch at one?')
    expect(screen.getByRole('button', { name: 'Send' })).toBeTruthy()
  })

  it('keeps the owner edit when the same draft is replayed with new text', () => {
    setDraft()
    render(<PendingApprovalStack />)

    fireEvent.click(screen.getByRole('button', { name: 'Edit' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Edit message' }), { target: { value: 'my edit' } })
    act(() => setDraft({ text: 'Lunch at one?' }))

    expect((screen.getByRole('textbox', { name: 'Edit message' }) as HTMLTextAreaElement).value).toBe('my edit')
  })

  it('an expired draft can only be discarded and says why', () => {
    setDraft({ editable: true, held: true, state: 'expired' })
    render(<PendingApprovalStack />)

    expect(screen.getByText(/Expired — this draft can no longer be sent/)).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Send' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Edit' })).toBeNull()
    expect(screen.getByRole('button', { name: 'Discard' })).toBeTruthy()
  })

  it('tells the owner a held draft was made while they were away', () => {
    setDraft({ held: true })
    render(<PendingApprovalStack />)

    expect(screen.getByText('Made while you were away. Nothing has been sent.')).toBeTruthy()
  })

  it('never answers a draft from the keyboard', () => {
    const respond = liveApproval()
    mockGateway()
    setDraft({}, { serverRequestId: 'srq-draft' })
    render(<PendingApprovalStack />)

    handleApprovalKey(new KeyboardEvent('keydown', { key: 'Enter', cancelable: true }))
    handleApprovalKey(new KeyboardEvent('keydown', { key: 'Escape', cancelable: true }))

    expect(respond).not.toHaveBeenCalled()
    expect(sessionApprovalRequests('sess-1').get()).toHaveLength(1)
  })
})

describe('Bot Chat approval card', () => {
  function setBotChat(extra: Record<string, unknown> = {}) {
    $activeSessionId.set('sess-1')
    setApprovalRequest({
      choices: ['once', 'always', 'deny'],
      command: 'chmod -R 777 /tmp/x',
      description: 'recursive chmod',
      requestId: 'apr-bot',
      scope: 'bot_chat',
      sessionId: 'sess-1',
      ...extra
    })
  }

  it('offers exactly Allow once, Always allow and Deny, with no session scope', () => {
    setBotChat()
    const { container } = render(<PendingApprovalStack />)

    expect(
      within(container.querySelector('[data-slot="tool-approval-actions"]') as HTMLElement)
        .getAllByRole('button')
        .map(button => button.textContent?.replace('↵', '').trim())
    ).toEqual(['Deny', 'Always allow', 'Allow once'])
    expect(screen.queryByText(/session/i)).toBeNull()
  })

  it('answers once and deny directly', async () => {
    const respond = liveApproval()
    mockGateway()
    setBotChat({ serverRequestId: 'srq-draft' })
    render(<PendingApprovalStack />)

    fireEvent.click(screen.getByRole('button', { name: /Allow once/ }))

    await waitFor(() => expect(respond).toHaveBeenCalledWith({ choice: 'once' }))
  })

  it('confirms before Always allow persists for the bot', async () => {
    const respond = liveApproval()
    mockGateway()
    setBotChat({ serverRequestId: 'srq-draft' })
    render(<PendingApprovalStack />)

    fireEvent.click(screen.getByRole('button', { name: 'Always allow' }))

    expect(respond).not.toHaveBeenCalled()
    expect(screen.getByText(/This bot will stop asking before/)).toBeTruthy()

    fireEvent.click(screen.getAllByRole('button', { name: 'Always allow' }).at(-1)!)

    await waitFor(() => expect(respond).toHaveBeenCalledWith({ choice: 'always' }))
  })

  it('hides Always allow when the backend forbids a permanent grant', () => {
    setBotChat({ choices: ['once', 'deny'] })
    render(<PendingApprovalStack />)

    expect(screen.queryByRole('button', { name: 'Always allow' })).toBeNull()
  })

  it('keeps the standard card outside the Bot Chat', () => {
    setBotChat({ choices: undefined, scope: undefined })
    render(<PendingApprovalStack />)

    expect(screen.getByRole('button', { name: /Run/ })).toBeTruthy()
    expect(screen.queryByRole('button', { name: /Allow once/ })).toBeNull()
  })
})
