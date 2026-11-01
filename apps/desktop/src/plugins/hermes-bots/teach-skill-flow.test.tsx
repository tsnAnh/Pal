import type { BotTeachStatus, DisplayLease } from '@hermes/plugin-sdk'
import { act, fireEvent, render, waitFor } from '@testing-library/react'
import type { ReactNode } from 'react'
import { beforeEach, expect, it, vi } from 'vitest'

import type * as ScreenConnection from './screen-connection'
import type { RosterRow } from './types'

const notify = vi.hoisted(() => vi.fn())
const requestForBot = vi.hoisted(() => vi.fn())

vi.mock('@hermes/plugin-sdk', async () => {
  const { useStore } = await import('@nanostores/react')
  const { TEACH_LOCALES } = await import('./teach-locales')

  const translate = (key: string, ...args: unknown[]) => {
    const leaf = key.split('.').reduce<unknown>((node, part) => (node as Record<string, unknown>)?.[part], { teach: TEACH_LOCALES.en })

    return typeof leaf === 'function' ? (leaf as (...a: unknown[]) => string)(...args) : String(leaf ?? key)
  }

  return {
    Button: ({ children, ...props }: React.ButtonHTMLAttributes<HTMLButtonElement>) => <button {...props}>{children}</button>,
    Codicon: () => null,
    ConfirmDialog: ({ confirmLabel, onClose, onConfirm, open, title }: { confirmLabel: string; onClose: () => void; onConfirm: () => Promise<void>; open: boolean; title: string }) =>
      open ? (
        <div role="alertdialog">
          <span>{title}</span>
          <button onClick={() => void onConfirm().then(onClose, () => undefined)}>{`confirm ${confirmLabel}`}</button>
        </div>
      ) : null,
    Dialog: ({ children, open }: { children: ReactNode; open: boolean }) => (open ? <div role="dialog">{children}</div> : null),
    DialogContent: ({ children }: { children: ReactNode }) => <div>{children}</div>,
    DialogDescription: ({ children }: { children: ReactNode }) => <p>{children}</p>,
    DialogFooter: ({ children }: { children: ReactNode }) => <div>{children}</div>,
    DialogHeader: ({ children }: { children: ReactNode }) => <div>{children}</div>,
    DialogTitle: ({ children }: { children: ReactNode }) => <h2>{children}</h2>,
    GlyphSpinner: () => null,
    Textarea: (props: React.TextareaHTMLAttributes<HTMLTextAreaElement>) => <textarea {...props} />,
    Tip: ({ children }: { children: ReactNode }) => <>{children}</>,
    host: { notify, retainProfile: async () => () => undefined },
    useValue: useStore,
    usePluginI18n: () => translate
  }
})
vi.mock('./routing', () => ({
  backendTargetProfile: (_route: unknown, fallback: string) => fallback,
  botConnectionRoute: () => null,
  botRosterMeta: () => null,
  requestForBot,
  resolveBotConnectionRoute: () => ({ route: null, status: 'not_scoped' })
}))
vi.mock('./labels', () => ({ displayName: (bot: RosterRow) => bot.name }))
vi.mock('./data', async () => {
  const { atom } = await import('nanostores')

  return { $botMeta: atom({}), botSelectionKey: (bot: RosterRow) => bot.name }
})
vi.mock('./screen-connection', async importActual => ({
  ...(await importActual<typeof ScreenConnection>()),
  displayRequest: vi.fn(),
  retainBotScreen: async () => () => undefined
}))

import { displayRequest } from './screen-connection'
import { $screenState } from './screen-state'
import { TeachSkillBanner, TeachSkillControls } from './teach-skill-controls'
import { $teachState, noteTeachSubmitted, setTeachStatus } from './teach-skill-state'

const bot: RosterRow = { canonical_session: { id: 'chat-1', resolved_id: 'chat-1-tip' }, name: 'scout' }
const viewer = { hash: 'hash-1', id: 'viewer-1' }
const NOW = 1_000

const agentLease: DisplayLease = { ask: '', ask_at: 0, epoch: 1, holder: 'agent', since: 1, viewer_hash: null, viewer_id: null } as DisplayLease
const humanLease = { ...agentLease, epoch: 2, holder: 'human', viewer_hash: viewer.hash } as DisplayLease

const status = (patch: Partial<BotTeachStatus> = {}): BotTeachStatus => ({
  available: true,
  capture: 'idle',
  event_count: 0,
  max_seconds: 600,
  now: NOW,
  recording: false,
  truncated: false,
  ...patch
})

const pending = (state: 'drafting' | 'ready') => ({ event_count: 4, skill_name: 'taught-shop-1a2b', state, teach_id: 'teach-1', truncated: false })

const SKILL = '---\nname: taught-shop-1a2b\ndescription: Download the weekly report.\n---\n\n# Report Skill\n'

let backend: BotTeachStatus
let rpcLog: Array<[string, Record<string, unknown>]>

function wire(overrides: Record<string, (params: Record<string, unknown>) => unknown> = {}) {
  vi.mocked(displayRequest).mockImplementation((async (_bot: RosterRow, method: string, params: Record<string, unknown> = {}) => {
    rpcLog.push([method, params])

    if (overrides[method]) {
      return overrides[method](params)
    }

    switch (method) {
      case 'bot.teach.status':
        return backend

      case 'display.lease.acquire':
        return { lease: humanLease }

      case 'display.lease.release':
        return { lease: { ...agentLease, epoch: 3 } }

      case 'bot.teach.start':
        backend = status({ capture: 'attached', deadline_at: NOW + 600, recording: true, started_at: NOW, teach_id: 'teach-1' })

        return backend

      case 'bot.teach.stop':
        backend = status({ pending: pending('drafting') })

        return { empty: false, event_count: 4, prompt: 'PROMPT WITH LOG', reason: 'owner', skill_name: 'taught-shop-1a2b', teach_id: 'teach-1', truncated: false }

      case 'bot.teach.draft':
        return { content: SKILL, content_hash: 'hash-1', event_count: 4, skill_name: 'taught-shop-1a2b', state: 'ready', teach_id: 'teach-1', truncated: false }

      case 'bot.teach.approve':
        backend = status()

        return { enabled: true, skill_name: 'taught-shop-1a2b', teach_id: 'teach-1' }

      case 'bot.teach.discard':
        backend = status()

        return { discarded: true, teach_id: 'teach-1' }

      default:
        throw new Error(`unexpected ${method}`)
    }
  }) as never)
}

const rpcs = (method: string) => rpcLog.filter(([m]) => m === method)

function Harness({ lease = agentLease, live = true }: { lease?: DisplayLease; live?: boolean }) {
  return (
    <>
      <TeachSkillControls bot={bot} lease={lease} live={live} viewer={viewer} />
      <TeachSkillBanner bot={bot} live={live} />
    </>
  )
}

beforeEach(() => {
  noteTeachSubmitted(bot, 0)
  noteTeachSubmitted({ name: 'scout' }, 0)
  $teachState.set({})
  $screenState.set({})
  backend = status()
  rpcLog = []
  notify.mockReset()
  requestForBot.mockReset().mockImplementation(async (_bot: RosterRow, method: string) => (method === 'session.resume' ? { session_id: 'runtime-1' } : {}))
  vi.mocked(displayRequest).mockReset()
  wire()
})

it('offers Teach a skill only when the backend says the bot can be taught', async () => {
  const view = render(<Harness />)
  await waitFor(() => expect(view.getByText('Teach a skill')).toBeTruthy())
  view.unmount()

  $teachState.set({})
  backend = status({ available: false, reason: 'sandbox' })
  const hidden = render(<Harness />)
  await waitFor(() => expect(rpcs('bot.teach.status')).toHaveLength(2))
  expect(hidden.queryByText('Teach a skill')).toBeNull()
})

it('hides the control on a gateway without the teach methods and never asks again', async () => {
  wire({ 'bot.teach.status': () => Promise.reject({ code: -32601, message: 'method not found' }) })
  const view = render(<Harness />)
  await waitFor(() => expect(rpcs('bot.teach.status')).toHaveLength(1))
  await act(async () => {})
  expect(view.queryByText('Teach a skill')).toBeNull()
  view.rerender(<Harness />)
  expect(rpcs('bot.teach.status')).toHaveLength(1)
})

it('stays hidden while the screen is not live', async () => {
  const view = render(<Harness live={false} />)
  await act(async () => {})
  expect(view.queryByText('Teach a skill')).toBeNull()
  expect(rpcs('bot.teach.status')).toHaveLength(0)
})

it('records, stops, hands the bot the recording as a hidden turn, then reviews and approves the draft', async () => {
  const view = render(<Harness />)
  fireEvent.click(await view.findByText('Teach a skill'))

  await waitFor(() => expect(view.getByText(/Recording ·/)).toBeTruthy())
  expect(rpcs('display.lease.acquire')[0][1]).toEqual({ reason: 'Teaching a skill', viewer_id: 'viewer-1' })
  expect(rpcs('bot.teach.start')[0][1]).toEqual({ viewer_id: 'viewer-1' })

  fireEvent.click(view.getByText('Stop'))
  await waitFor(() => expect(view.getByText('scout is writing the skill…')).toBeTruthy())

  expect(rpcs('bot.teach.stop')[0][1]).toEqual({ discard: false })
  expect(requestForBot).toHaveBeenCalledWith(bot, 'session.resume', { omit_messages: true, profile: 'scout', session_id: 'chat-1-tip' }, { spawnPriority: 'foreground' })
  expect(requestForBot).toHaveBeenCalledWith(bot, 'prompt.submit', { display_kind: 'hidden', session_id: 'runtime-1', text: 'PROMPT WITH LOG' })
  expect(rpcs('display.lease.release')).toHaveLength(1)
  expect(view.queryByText('Review')).toBeNull()
  expect((view.getByText('Ask again').closest('button') as HTMLButtonElement).disabled).toBe(true)

  act(() => setTeachStatus(bot, status({ pending: pending('ready') })))
  fireEvent.click(await view.findByText('Review'))
  const editor = (await view.findByLabelText('Review the skill')) as HTMLTextAreaElement
  expect(editor.value).toBe(SKILL)
  expect(editor.readOnly).toBe(true)

  fireEvent.click(view.getByText('Approve'))
  await waitFor(() => expect(rpcs('bot.teach.approve')).toHaveLength(1))
  expect(rpcs('bot.teach.approve')[0][1]).toEqual({ content_hash: 'hash-1', teach_id: 'teach-1' })
  expect(notify).toHaveBeenCalledWith({ kind: 'success', message: 'Skill approved: taught-shop-1a2b' })
  await waitFor(() => expect(view.queryByRole('dialog')).toBeNull())
  await waitFor(() => expect(view.queryByText('scout wrote a skill for you to review')).toBeNull())
  expect(view.getByText('Teach a skill')).toBeTruthy()
})

it('keeps the screen when the owner was already in control before teaching', async () => {
  const view = render(<Harness lease={humanLease} />)
  fireEvent.click(await view.findByText('Teach a skill'))
  await waitFor(() => expect(view.getByText('Stop')).toBeTruthy())
  expect(rpcs('display.lease.acquire')).toHaveLength(0)
  fireEvent.click(view.getByText('Stop'))
  await waitFor(() => expect(rpcs('bot.teach.stop')).toHaveLength(1))
  await act(async () => {})
  expect(rpcs('display.lease.release')).toHaveLength(0)
})

it('gives control back and says why when the recording cannot start', async () => {
  wire({ 'bot.teach.start': () => Promise.reject({ data: { code: 'draft_pending' }, message: 'x' }) })
  const view = render(<Harness />)
  fireEvent.click(await view.findByText('Teach a skill'))
  await waitFor(() => expect(notify).toHaveBeenCalledWith({ kind: 'error', message: 'Review or discard the previous draft first.' }))
  expect(rpcs('display.lease.release')).toHaveLength(1)
  expect(view.queryByText(/Recording ·/)).toBeNull()
})

it('creates nothing and sends nothing when no step was recorded', async () => {
  wire({ 'bot.teach.stop': () => ({ empty: true, reason: 'owner' }) })
  const view = render(<Harness lease={humanLease} />)
  fireEvent.click(await view.findByText('Teach a skill'))
  fireEvent.click(await view.findByText('Stop'))
  await waitFor(() => expect(notify).toHaveBeenCalledWith({ kind: 'info', message: 'Nothing was recorded, so no skill was created.' }))
  expect(requestForBot).not.toHaveBeenCalled()
})

it('keeps the draft and offers Ask again when the recording could not be delivered', async () => {
  requestForBot.mockImplementation(async (_bot: RosterRow, method: string) => {
    if (method === 'prompt.submit') {
      throw new Error('socket closed')
    }

    return { session_id: 'runtime-1' }
  })
  const view = render(<Harness lease={humanLease} />)
  fireEvent.click(await view.findByText('Teach a skill'))
  fireEvent.click(await view.findByText('Stop'))
  await waitFor(() => expect(notify).toHaveBeenCalledWith({ kind: 'error', message: 'Could not send the recording to scout.' }))
  await view.findByText('Ask again')

  requestForBot.mockImplementation(async (_bot: RosterRow, method: string) => (method === 'session.resume' ? { session_id: 'runtime-2' } : {}))
  wire({ 'bot.teach.prompt': () => ({ prompt: 'PROMPT AGAIN' }) })
  fireEvent.click(view.getByText('Ask again'))
  await waitFor(() => expect(requestForBot).toHaveBeenCalledWith(bot, 'prompt.submit', { display_kind: 'hidden', session_id: 'runtime-2', text: 'PROMPT AGAIN' }))
})

it('asks the owner to open the chat once when the bot has no Bot Chat yet', async () => {
  const noChat: RosterRow = { name: 'scout' }

  const view = render(
    <>
      <TeachSkillControls bot={noChat} lease={humanLease} live viewer={viewer} />
      <TeachSkillBanner bot={noChat} live />
    </>
  )

  fireEvent.click(await view.findByText('Teach a skill'))
  fireEvent.click(await view.findByText('Stop'))
  await waitFor(() => expect(notify).toHaveBeenCalledWith({ kind: 'error', message: "Open scout's chat once, then try again." }))
  expect(requestForBot).not.toHaveBeenCalled()
  await view.findByText('Ask again')
})

it('edits the draft and approves the edited text in one step; the draft stays off until then', async () => {
  backend = status({ pending: pending('ready') })
  const view = render(<Harness />)
  fireEvent.click(await view.findByText('Review'))
  const editor = (await view.findByLabelText('Review the skill')) as HTMLTextAreaElement
  fireEvent.click(view.getByText('Edit'))
  expect(editor.readOnly).toBe(false)
  fireEvent.change(editor, { target: { value: `${SKILL}\nMore.` } })
  fireEvent.click(view.getByText('Approve'))
  await waitFor(() => expect(rpcs('bot.teach.approve')).toHaveLength(1))
  expect(rpcs('bot.teach.approve')[0][1]).toEqual({ content: `${SKILL}\nMore.`, teach_id: 'teach-1' })
})

it('saves an edit without approving it', async () => {
  wire({ 'bot.teach.draft.save': params => ({ content: params.content, event_count: 4, skill_name: 'taught-shop-1a2b', state: 'ready', teach_id: 'teach-1', truncated: false }) })
  backend = status({ pending: pending('ready') })
  const view = render(<Harness />)
  fireEvent.click(await view.findByText('Review'))
  const editor = (await view.findByLabelText('Review the skill')) as HTMLTextAreaElement
  fireEvent.click(view.getByText('Edit'))
  fireEvent.change(editor, { target: { value: `${SKILL}\nEdited.` } })
  fireEvent.click(view.getByText('Save changes'))
  await waitFor(() => expect(rpcs('bot.teach.draft.save')).toHaveLength(1))
  expect(rpcs('bot.teach.approve')).toHaveLength(0)
  await waitFor(() => expect((view.getByLabelText('Review the skill') as HTMLTextAreaElement).readOnly).toBe(true))
  expect((view.getByLabelText('Review the skill') as HTMLTextAreaElement).value).toContain('Edited.')
})

it('shows why an approval was refused and leaves the draft in place', async () => {
  wire({ 'bot.teach.approve': () => Promise.reject({ data: { code: 'invalid_skill' }, message: 'Description is 80 chars; too long.' }) })
  backend = status({ pending: pending('ready') })
  const view = render(<Harness />)
  fireEvent.click(await view.findByText('Review'))
  await view.findByLabelText('Review the skill')
  fireEvent.click(view.getByText('Approve'))
  await view.findByText('Description is 80 chars; too long.')
  expect(view.getByRole('dialog')).toBeTruthy()
  expect(notify).not.toHaveBeenCalledWith(expect.objectContaining({ kind: 'success' }))
})

it('discards the draft only after confirmation', async () => {
  backend = status({ pending: pending('ready') })
  const view = render(<Harness />)
  fireEvent.click(await view.findByText('Review'))
  await view.findByLabelText('Review the skill')
  fireEvent.click(view.getAllByText('Discard')[0])
  await view.findByText('Discard this draft?')
  expect(rpcs('bot.teach.discard')).toHaveLength(0)
  fireEvent.click(view.getByText('confirm Discard'))
  await waitFor(() => expect(rpcs('bot.teach.discard')).toHaveLength(1))
  expect(rpcs('bot.teach.discard')[0][1]).toEqual({ teach_id: 'teach-1' })
  await waitFor(() => expect(view.queryByText('scout wrote a skill for you to review')).toBeNull())
})

it('an ended recording waits for the owner: Create skill finishes it, Discard throws it away', async () => {
  wire({ 'bot.teach.stop': params => ({ empty: Boolean(params.discard), reason: 'limit' }) })
  backend = status({ ended: 'limit', event_count: 4, teach_id: 'teach-1' })
  const view = render(<Harness lease={humanLease} />)
  await view.findByText('Recording stopped at the 10 minute limit')
  fireEvent.click(view.getByText('Discard'))
  await waitFor(() => expect(rpcs('bot.teach.stop')).toHaveLength(1))
  expect(rpcs('bot.teach.stop')[0][1]).toEqual({ discard: true })
  expect(requestForBot).not.toHaveBeenCalled()
})

it('will not offer to approve a draft that carries files the owner cannot review', async () => {
  wire({
    'bot.teach.draft': () => ({
      content: SKILL,
      content_hash: 'hash-1',
      event_count: 4,
      extra_files: ['scripts/run.py'],
      skill_name: 'taught-shop-1a2b',
      state: 'ready',
      teach_id: 'teach-1',
      truncated: false
    })
  })
  backend = status({ pending: pending('ready') })
  const view = render(<Harness />)
  fireEvent.click(await view.findByText('Review'))
  await view.findByText(/also contains other files \(scripts\/run.py\)/)
  expect((view.getByText('Approve').closest('button') as HTMLButtonElement).disabled).toBe(true)
  expect(rpcs('bot.teach.approve')).toHaveLength(0)
})

it('tells the owner when the bot changed the draft during the review and shows the new text', async () => {
  let reads = 0
  wire({
    'bot.teach.approve': () => Promise.reject({ data: { code: 'draft_changed' }, message: 'x' }),
    'bot.teach.draft': () => {
      reads += 1

      return { content: reads === 1 ? SKILL : `${SKILL}\nNew version.`, content_hash: `hash-${reads}`, event_count: 4, skill_name: 'taught-shop-1a2b', state: 'ready', teach_id: 'teach-1', truncated: false }
    }
  })
  backend = status({ pending: pending('ready') })
  const view = render(<Harness />)
  fireEvent.click(await view.findByText('Review'))
  await view.findByLabelText('Review the skill')
  fireEvent.click(view.getByText('Approve'))
  await view.findByText('The draft changed while you were reviewing it. Review the new version before approving.')
  await waitFor(() => expect((view.getByLabelText('Review the skill') as HTMLTextAreaElement).value).toContain('New version.'))
  expect(notify).not.toHaveBeenCalledWith(expect.objectContaining({ kind: 'success' }))
})

it('does not give back a screen that the recording itself already lost', async () => {
  wire({ 'bot.teach.stop': () => ({ empty: false, event_count: 4, prompt: 'P', reason: 'control_returned', skill_name: 'taught-shop-1a2b', teach_id: 'teach-1', truncated: false }) })
  const view = render(<Harness />)
  fireEvent.click(await view.findByText('Teach a skill'))
  fireEvent.click(await view.findByText('Stop'))
  await waitFor(() => expect(requestForBot).toHaveBeenCalledWith(bot, 'prompt.submit', expect.anything()))
  expect(rpcs('display.lease.release')).toHaveLength(0)
})
